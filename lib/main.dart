import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kBaseApiUrl = 'https://vocab.codehutbd.com';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShohojVocabApp());
}

class ShohojVocabApp extends StatelessWidget {
  const ShohojVocabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shohoj Vocab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4F46E5),
        scaffoldBackgroundColor: const Color(0xFFF5F7FF),
      ),
      home: const ShohojVocabHomeShell(),
    );
  }
}

class VocabWord {
  final String eng;
  final String bng;
  final String sourceKey;

  VocabWord({required this.eng, required this.bng, required this.sourceKey});

  factory VocabWord.fromJson(Map<String, dynamic> j, String key) {
    return VocabWord(
      eng: (j['eng'] ?? '').toString(),
      bng: (j['bng'] ?? '').toString(),
      sourceKey: key,
    );
  }

  Map<String, dynamic> toJson() => {'eng': eng, 'bng': bng, 'sourceKey': sourceKey};
}

class ShohojVocabHomeShell extends StatefulWidget {
  const ShohojVocabHomeShell({super.key});

  @override
  State<ShohojVocabHomeShell> createState() => _ShohojVocabHomeShellState();
}

class _ShohojVocabHomeShellState extends State<ShohojVocabHomeShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  SharedPreferences? _prefs;

  Map<String, List<VocabWord>> _vocabDb = {};
  bool _loadingDb = true;

  // Navigation Screen: 'landing', 'menu', 'category', 'verb_pages', 'set_map', 'practice'
  String _screen = 'landing';
  String _currentMode = 'guided'; // 'guided', 'flashcard', 'mcq', 'spelling'
  String _currentCategory = 'verb';
  List<String> _activeKeys = ['page1'];
  String _activeTitle = 'Verb Page 1';
  final int _batchSize = 5;

  // Auth & Cloud State
  String? _authToken;
  String? _username;
  bool _isMasterAdmin = false;
  String _announcement = '';
  bool _aiEnabled = true;
  List<dynamic> _leaderboard = [];

  // Master Admin Remote Configurable Game Rules
  int _adminMaxHearts = 3;
  int _adminTimerSeconds = 15;
  int _adminMistakeLimit = 10;
  bool _adminAntiCheat = true;

  // User Progress State
  List<String> _masteredWords = [];
  List<Map<String, String>> _hardWords = [];
  Map<String, bool> _completedSets = {};
  Map<String, bool> _passedRevisions = {};
  Map<String, String> _customNotes = {};
  int _streakDays = 1;
  String _lastStudyDate = '';
  Map<String, dynamic>? _lastSession;
  final ScrollController _setMapScrollController = ScrollController();

  // Practice Session State
  List<VocabWord> _categoryFullWords = [];
  List<VocabWord> _wordsArray = [];
  int _currentSetIndex = 0;
  int _currentWordIndex = 0;
  int _guidedStep = 1;
  int _maxUnlockedGuidedStep = 1;
  Set<int> _seenInStep1 = {0};
  bool _isRevisionSession = false;
  int _activeRevisionGroup = -1;

  // Hard Discipline Mode State
  int _sessionHearts = 3;
  int _questionTimeLeft = 15;
  Timer? _questionTimer;
  Timer? _glowStepTimer1;
  Timer? _glowStepTimer2;
  int _activeGlowStep = 1; // 1 -> 2 -> 3 sequential glow highlight like website!
  bool _usedHintOnCurrentWord = false;
  bool _audioOnlySpelling = false;
  bool _flashcardFlipped = false;
  bool _wasPausedDuringQuiz = false;

  // Step 2 Match State
  List<VocabWord> _matchEngList = [];
  List<VocabWord> _matchBngList = [];
  String? _selectedMatchEng;
  String? _selectedMatchBng;
  final Set<String> _matchedWords = {};

  // Step 3 MCQ State
  List<String> _mcqOptions = [];
  String _mcqSelected = '';
  String _mcqFeedback = '';
  bool _mcqEngToBng = true;

  // Step 4 Spelling State
  final TextEditingController _spellController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  List<String> _tilePool = [];
  final List<int> _usedTileIndices = [];
  String _spellFeedback = '';

  late AnimationController _sceneAnimController;
  late AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sceneAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _initApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _questionTimer?.cancel();
    _glowStepTimer1?.cancel();
    _glowStepTimer2?.cancel();
    _sceneAnimController.dispose();
    _shakeController.dispose();
    _setMapScrollController.dispose();
    _spellController.dispose();
    _noteController.dispose();
    _tts.stop();
    super.dispose();
  }

  // Android-Exclusive Anti-Cheat App Switch Lifecycle Detection
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final inTimedTest = _screen == 'practice' &&
        ((_currentMode == 'guided' && _guidedStep >= 2) ||
            _currentMode == 'mcq' ||
            _currentMode == 'spelling');
    if (!inTimedTest) {
      if (state == AppLifecycleState.resumed) {
        _fetchPublicConfigAndSync();
      }
      return;
    }
    if (!_adminAntiCheat) return;

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _wasPausedDuringQuiz = true;
    } else if (state == AppLifecycleState.resumed && _wasPausedDuringQuiz) {
      _wasPausedDuringQuiz = false;
      HapticFeedback.heavyImpact();
      _shakeController.forward(from: 0);
      _deductHeartAndCheckReset(
        '🚨 অ্যান্টি-চিট পেনাল্টি! কুইজ চলাকালীন অ্যাপ পরিবর্তন করায় ১টি লাইফ কাটা হয়েছে!',
      );
    }
  }

  Future<void> _initApp() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    _prefs = await SharedPreferences.getInstance();

    final rawJson = await rootBundle.loadString('assets/vocab_db.json');
    final Map<String, dynamic> decoded = jsonDecode(rawJson);
    final Map<String, List<VocabWord>> parsed = {};
    decoded.forEach((key, list) {
      if (list is List) {
        parsed[key] = list.map((item) => VocabWord.fromJson(item, key)).toList();
      }
    });

    _authToken = _prefs?.getString('authToken');
    _username = _prefs?.getString('username');
    _isMasterAdmin = _prefs?.getBool('isMasterAdmin') ?? false;
    _adminMaxHearts = _prefs?.getInt('adminMaxHearts') ?? 3;
    _adminTimerSeconds = _prefs?.getInt('adminTimerSeconds') ?? 15;
    _adminMistakeLimit = _prefs?.getInt('adminMistakeLimit') ?? 10;
    _adminAntiCheat = _prefs?.getBool('adminAntiCheat') ?? true;
    _sessionHearts = _adminMaxHearts;
    _loadLocalProgress();

    setState(() {
      _vocabDb = parsed;
      _loadingDb = false;
      if (_username != null && _username!.isNotEmpty) {
        _screen = 'menu';
      }
    });

    await _fetchPublicConfigAndSync();
  }

  void _loadLocalProgress() {
    if (_prefs == null) return;
    _masteredWords = _prefs!.getStringList('masteredWords') ?? [];
    final rawHard = _prefs!.getString('hardWords');
    if (rawHard != null) {
      final List<dynamic> list = jsonDecode(rawHard);
      _hardWords = list
          .map((e) => {'eng': (e['eng'] ?? '').toString(), 'bng': (e['bng'] ?? '').toString()})
          .toList();
    }
    final rawSets = _prefs!.getString('completedSets');
    if (rawSets != null) {
      final Map<String, dynamic> m = jsonDecode(rawSets);
      _completedSets = m.map((k, v) => MapEntry(k, v == true));
    }
    final rawRevs = _prefs!.getString('passedRevisions');
    if (rawRevs != null) {
      final Map<String, dynamic> m = jsonDecode(rawRevs);
      _passedRevisions = m.map((k, v) => MapEntry(k, v == true));
    }
    final rawNotes = _prefs!.getString('customNotes');
    if (rawNotes != null) {
      final Map<String, dynamic> m = jsonDecode(rawNotes);
      _customNotes = m.map((k, v) => MapEntry(k, v.toString()));
    }
    _streakDays = _prefs!.getInt('streakDays') ?? 1;
    _lastStudyDate = _prefs!.getString('lastStudyDate') ?? '';
    final rawLast = _prefs!.getString('lastSession');
    if (rawLast != null && rawLast.isNotEmpty) {
      try {
        _lastSession = Map<String, dynamic>.from(jsonDecode(rawLast));
      } catch (_) {}
    }
    _lastSession ??= _deriveSessionFromCompletedSets();
  }

  Map<String, dynamic>? _deriveSessionFromCompletedSets() {
    final trueKeys = _completedSets.entries.where((e) => e.value).map((e) => e.key).toList();
    if (trueKeys.isEmpty) return null;
    final Map<String, int> highestNextSet = {};
    for (final k in trueKeys) {
      final m = RegExp(r'^(.+)_(\d+)_(\d+)$').firstMatch(k);
      if (m != null) {
        final gk = m.group(1)!;
        final sIdx = int.tryParse(m.group(3)!) ?? 0;
        if (!highestNextSet.containsKey(gk) || sIdx + 1 > highestNextSet[gk]!) {
          highestNextSet[gk] = sIdx + 1;
        }
      }
    }
    if (highestNextSet.isEmpty) return null;
    final sortedKeys = highestNextSet.keys.toList()
      ..sort((a, b) => highestNextSet[b]!.compareTo(highestNextSet[a]!));
    final bestGk = sortedKeys.first;
    final nextSet = highestNextSet[bestGk]!;
    final cat = bestGk.startsWith('page') ? 'verb' : bestGk;
    final title = bestGk.startsWith('page')
        ? 'Verb Page ${bestGk.replaceAll('page', '')}'
        : '${bestGk.toUpperCase()} এর শব্দসমূহ';
    return {
      'sectionId': 'set-selection',
      'currentMode': 'guided',
      'currentCategory': cat,
      'activeKeys': [bestGk],
      'activeTitleLabel': title,
      'batchSize': _batchSize,
      'currentSetIndex': nextSet,
      'currentWordIndex': 0,
      'guidedStep': 1,
      'maxUnlockedGuidedStep': 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  void _updateLastSessionSnapshot() {
    if (_screen != 'set_map' && _screen != 'practice') return;
    _lastSession = {
      'sectionId': _screen == 'practice' ? 'practice-area' : 'set-selection',
      'currentMode': _currentMode,
      'currentCategory': _currentCategory,
      'activeKeys': _activeKeys,
      'activeTitleLabel': _activeTitle,
      'batchSize': _batchSize,
      'currentSetIndex': _currentSetIndex,
      'currentWordIndex': _currentWordIndex,
      'guidedStep': _guidedStep,
      'maxUnlockedGuidedStep': _maxUnlockedGuidedStep,
      'isRevisionSession': _isRevisionSession,
      'activeRevisionGroup': _activeRevisionGroup,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> _saveLocalProgress() async {
    if (_prefs == null) return;
    _updateLastSessionSnapshot();
    await _prefs!.setStringList('masteredWords', _masteredWords);
    await _prefs!.setString('hardWords', jsonEncode(_hardWords));
    await _prefs!.setString('completedSets', jsonEncode(_completedSets));
    await _prefs!.setString('passedRevisions', jsonEncode(_passedRevisions));
    await _prefs!.setString('customNotes', jsonEncode(_customNotes));
    await _prefs!.setInt('streakDays', _streakDays);
    await _prefs!.setString('lastStudyDate', _lastStudyDate);
    if (_lastSession != null) {
      await _prefs!.setString('lastSession', jsonEncode(_lastSession));
    }
  }

  Map<String, dynamic> _exportProgressPayload() {
    _updateLastSessionSnapshot();
    final sess = _lastSession ?? _deriveSessionFromCompletedSets();
    final catLabel = (sess?['currentCategory'] ?? _currentCategory).toString().toUpperCase();
    final setNum = (int.tryParse((sess?['currentSetIndex'] ?? _currentSetIndex).toString()) ?? 0) + 1;
    final stepNum = int.tryParse((sess?['guidedStep'] ?? _guidedStep).toString()) ?? 1;
    return {
      'masteredWords': _masteredWords,
      'hardWords': _hardWords,
      'completedSets': _completedSets,
      'passedRevisions': _passedRevisions,
      'customNotes': _customNotes,
      'streakDays': _streakDays,
      'lastStudyDate': _lastStudyDate,
      'lastSession': sess,
      'currentLevelLabel': '$catLabel — সেট $setNum (ধাপ $stepNum)',
    };
  }

  void _importProgressPayload(Map<String, dynamic>? prog) {
    if (prog == null) return;
    setState(() {
      if (prog['completedSets'] is Map) {
        (prog['completedSets'] as Map).forEach((k, v) {
          if (v == true) _completedSets[k.toString()] = true;
        });
      }
      if (prog['passedRevisions'] is Map) {
        (prog['passedRevisions'] as Map).forEach((k, v) {
          if (v == true) _passedRevisions[k.toString()] = true;
        });
      }
      if (prog['masteredWords'] is List) {
        final mergedM = <String>{..._masteredWords};
        for (final e in (prog['masteredWords'] as List)) {
          final s = e.toString().trim();
          if (s.isNotEmpty) mergedM.add(s);
        }
        _masteredWords = mergedM.toList();
      }
      if (prog['hardWords'] is List) {
        final existingEng = _hardWords.map((e) => e['eng']).toSet();
        for (final e in (prog['hardWords'] as List)) {
          if (e is Map) {
            final eng = (e['eng'] ?? '').toString();
            final bng = (e['bng'] ?? '').toString();
            if (eng.isNotEmpty && !existingEng.contains(eng) && !_masteredWords.contains(eng)) {
              _hardWords.add({'eng': eng, 'bng': bng});
              existingEng.add(eng);
            }
          }
        }
      }
      if (prog['customNotes'] is Map) {
        (prog['customNotes'] as Map).forEach((k, v) {
          if (v != null && v.toString().isNotEmpty) {
            _customNotes[k.toString()] = v.toString();
          }
        });
      }
      if (prog['streakDays'] != null) {
        final remoteStreak = int.tryParse(prog['streakDays'].toString()) ?? 1;
        if (remoteStreak > _streakDays) _streakDays = remoteStreak;
      }
      if (prog['lastStudyDate'] != null) {
        final rDate = prog['lastStudyDate'].toString();
        if (rDate.compareTo(_lastStudyDate) > 0) _lastStudyDate = rDate;
      }
      if (prog['lastSession'] is Map) {
        final remoteSess = Map<String, dynamic>.from(prog['lastSession']);
        if (remoteSess['currentCategory'] != null) {
          final localTs = int.tryParse((_lastSession?['updatedAt'] ?? '0').toString()) ?? 0;
          final remoteTs = int.tryParse((remoteSess['updatedAt'] ?? '1').toString()) ?? 1;
          if (_lastSession == null || remoteTs >= localTs) {
            _lastSession = remoteSess;
          }
        }
      }
      _lastSession ??= _deriveSessionFromCompletedSets();
    });
    _saveLocalProgress();
  }

  Map<String, String> _apiHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_authToken != null && _authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    return headers;
  }

  Future<void> _fetchPublicConfigAndSync() async {
    try {
      final cfgRes = await http
          .get(Uri.parse('$kBaseApiUrl/api/public/config'))
          .timeout(const Duration(seconds: 8));
      if (cfgRes.statusCode == 200) {
        final data = jsonDecode(cfgRes.body);
        setState(() {
          _aiEnabled = data['ai_enabled'] == true;
          _announcement = (data['announcement'] ?? '').toString();
          _leaderboard = (data['leaderboard'] as List?) ?? [];
          if (data['max_hearts'] != null) {
            _adminMaxHearts = int.tryParse(data['max_hearts'].toString()) ?? 3;
            _prefs?.setInt('adminMaxHearts', _adminMaxHearts);
          }
          if (data['timer_seconds'] != null) {
            _adminTimerSeconds = int.tryParse(data['timer_seconds'].toString()) ?? 15;
            _prefs?.setInt('adminTimerSeconds', _adminTimerSeconds);
          }
          if (data['mistake_limit'] != null) {
            _adminMistakeLimit = int.tryParse(data['mistake_limit'].toString()) ?? 10;
            _prefs?.setInt('adminMistakeLimit', _adminMistakeLimit);
          }
          if (data['anti_cheat_enabled'] != null) {
            _adminAntiCheat = data['anti_cheat_enabled'] == true;
            _prefs?.setBool('adminAntiCheat', _adminAntiCheat);
          }
          if (_screen != 'practice') {
            _sessionHearts = _adminMaxHearts;
          }
        });
      }
      if (_authToken != null && _authToken!.isNotEmpty) {
        final meRes = await http
            .get(Uri.parse('$kBaseApiUrl/api/auth/me'), headers: _apiHeaders())
            .timeout(const Duration(seconds: 8));
        if (meRes.statusCode == 200) {
          final meData = jsonDecode(meRes.body);
          if (meData['banned'] == true) {
            _handleBannedLogout();
            return;
          }
          if (meData['ok'] == true && meData['user'] != null) {
            _importProgressPayload(meData['user']['progress']);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _syncProgressToServer() async {
    await _saveLocalProgress();
    if (_authToken == null || _isMasterAdmin) return;
    try {
      final res = await http
          .post(
            Uri.parse('$kBaseApiUrl/api/progress/save'),
            headers: _apiHeaders(),
            body: jsonEncode({'progress': _exportProgressPayload()}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 403) {
        _handleBannedLogout();
        return;
      }
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        if (d['ok'] == true && d['progress'] is Map) {
          _importProgressPayload(Map<String, dynamic>.from(d['progress']));
        }
      }
    } catch (_) {}
  }

  void _handleBannedLogout() {
    _questionTimer?.cancel();
    setState(() {
      _authToken = null;
      _username = null;
      _isMasterAdmin = false;
      _screen = 'landing';
    });
    _prefs?.remove('authToken');
    _prefs?.remove('username');
    _prefs?.remove('isMasterAdmin');
    _showSnack('🚫 আপনার অ্যাকাউন্টটি অ্যাডমিন কর্তৃক স্থগিত (Ban) করা হয়েছে!', isError: true);
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? Colors.red.shade700 : const Color(0xFF4F46E5),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _speak(String text, {double rate = 0.45}) async {
    final clean = text.replaceAll(RegExp(r'\(.*?\)'), '').replaceAll('/', ' or ').trim();
    await _tts.stop();
    await _tts.setSpeechRate(rate);
    await _tts.speak(clean);
  }

  // ===========================================================================
  // WORD HELPERS, SYLLABLES, VISUAL SCENE ENGINE & SEQUENTIAL GLOW
  // ===========================================================================
  String _cleanPrimaryWord(String raw) {
    var c = raw.replaceAll(RegExp(r'\(.*?\)'), '').trim();
    if (c.contains('/')) c = c.split('/')[0].trim();
    return c.isEmpty ? raw.trim() : c;
  }

  String _formatSyllables(String raw) {
    final w = _cleanPrimaryWord(raw);
    if (w.length <= 4) return w;
    final parts = RegExp(r'[^aeiouy]*[aeiouy]+(?:[^aeiouy](?![aeiouy]))*', caseSensitive: false)
        .allMatches(w)
        .map((m) => m.group(0)!)
        .toList();
    if (parts.length <= 1) return w;
    return parts.join(' • ');
  }

  void _triggerSequentialGlowAnimation() {
    _glowStepTimer1?.cancel();
    _glowStepTimer2?.cancel();
    setState(() => _activeGlowStep = 1);
    _sceneAnimController.forward(from: 0).then((_) => _sceneAnimController.repeat(reverse: true));
    _glowStepTimer1 = Timer(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _activeGlowStep = 2);
    });
    _glowStepTimer2 = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _activeGlowStep = 3);
    });
  }

  static const Map<String, Map<String, String>> _curatedWords = {
    'do': {
      'sceneType': 'study',
      'icon1': '🧑‍💻',
      'icon2': '✍️',
      'icon3': '✅',
      'exEng': 'I do my homework every day.',
      'exBng': 'আমি প্রতিদিন আমার বাড়ির কাজ করি।',
      'step1': '১. আমি (Subject 👤)',
      'step2': '২. কাজটি করছি (Do = করা) ⚡',
      'step3': '৩. কাজ সম্পন্ন! ✅',
    },
    'go': {
      'sceneType': 'travel',
      'icon1': '🏠',
      'icon2': '🚶‍♂️',
      'icon3': '🏫',
      'exEng': 'We go to school every morning.',
      'exBng': 'আমরা প্রতিদিন সকালে স্কুলে যাই।',
      'step1': '১. বাসা থেকে রওনা 🏠',
      'step2': '২. সামনে এগিয়ে যাওয়া (Go) 🚶‍♂️',
      'step3': '৩. গন্তব্যে পৌঁছানো 🏫',
    },
    'sit': {
      'sceneType': 'rise',
      'icon1': '🧍',
      'icon2': '🪑',
      'icon3': '🧘',
      'exEng': 'Please sit on this chair.',
      'exBng': 'অনুগ্রহ করে এই চেয়ারটিতে বসুন।',
      'step1': '১. দাঁড়িয়ে থাকা অবস্থা 🧍',
      'step2': '২. চেয়ারে বসা (Sit) 🪑',
      'step3': '৩. আরাম করে বসা 🧘',
    },
    'see': {
      'sceneType': 'vision',
      'icon1': '👀',
      'icon2': '🔭',
      'icon3': '🌈',
      'exEng': 'I can see a beautiful bird.',
      'exBng': 'আমি একটি সুন্দর পাখি দেখতে পাচ্ছি।',
      'step1': '১. চোখ খোলা 👀',
      'step2': '২. সামনে তাকানো (See = দেখা) 🔭',
      'step3': '৩. দৃশ্যটি স্পষ্ট দেখা 🌈',
    },
    'give': {
      'sceneType': 'exchange',
      'icon1': '🧑',
      'icon2': '🎁',
      'icon3': '👩',
      'exEng': 'Please give me the book.',
      'exBng': 'অনুগ্রহ করে আমাকে বইটি দিন।',
      'step1': '১. নিজের হাতে থাকা 🤲',
      'step2': '২. অন্যকে দেওয়া (Give) 🎁',
      'step3': '৩. অন্যজন পেল 😊',
    },
    'swim': {
      'sceneType': 'water',
      'icon1': '🌊',
      'icon2': '🏊‍♂️',
      'icon3': '🏝️',
      'exEng': 'He likes to swim in the river.',
      'exBng': 'সে নদীতে সাঁতার কাটতে পছন্দ করে।',
      'step1': '১. পানিতে নামা 🌊',
      'step2': '২. সাঁতার কাটা (Swim) 🏊‍♂️',
      'step3': '৩. তীরে এগিয়ে যাওয়া 🏝️',
    },
  };

  Map<String, String> _getWordVisualAndExample(VocabWord w) {
    final clean = _cleanPrimaryWord(w.eng);
    final low = clean.toLowerCase();
    final shortBng = w.bng.split('/')[0].replaceAll(RegExp(r'\(.*?\)'), '').trim();

    if (_curatedWords.containsKey(low)) {
      final c = Map<String, String>.from(_curatedWords[low]!);
      c['clean'] = clean;
      c['shortBng'] = shortBng;
      c['freqDays'] = '5';
      return c;
    }

    final cat = w.sourceKey.toLowerCase();
    final isNoun = cat == 'noun';
    final isAdj = cat == 'adjective';
    final isAdv = cat == 'adverb';
    final combined = ' $low ${w.bng} ';

    bool hasMatch(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(combined);

    String sceneType = 'study';
    String icon1 = '✨', icon2 = '🎯', icon3 = '🌟';
    int freqDays = 5;
    String exEng = '';
    String exBng = '';
    String step1 = '';
    String step2 = '';
    String step3 = '';

    if (isNoun) {
      if (hasMatch(r'\b(child|kid|baby|son|daughter|infant)\b|শিশু|বাচ্চা|সন্তান|ছেলে|মেয়ে')) {
        sceneType = 'exchange';
        icon1 = '👶'; icon2 = '🧸'; icon3 = '👨‍👩‍👧';
        exEng = 'Every $low needs love and care.';
        exBng = 'প্রতিটি $shortBng-র আদর ও যত্ন প্রয়োজন।';
        step1 = '১. ছোট্ট মণি 👶';
        step2 = '২. পরিচয়: $clean ($shortBng) 🧸';
        step3 = '৩. পরিবারের আদর 👨‍👩‍👧';
      } else if (hasMatch(r'\b(pupil|student|scholar|learner|teacher)\b|ছাত্র|শিক্ষার্থী|শিক্ষক')) {
        sceneType = 'study';
        icon1 = '🎒'; icon2 = '🧑‍🎓'; icon3 = '🏫';
        exEng = 'The $low is learning attentively in class.';
        exBng = '$shortBng-টি শ্রেণিকক্ষে মনোযোগ দিয়ে শিখছে।';
        step1 = '১. বিদ্যালয়ে আগমন 🎒';
        step2 = '২. পরিচয়: $clean ($shortBng) 🧑‍🎓';
        step3 = '৩. উজ্জ্বল ভবিষ্যৎ 🏫';
      } else if (hasMatch(r'\b(thief|robber|criminal|enemy|pirate)\b|চোর|ডাকাত|শত্রু|অপরাধী')) {
        sceneType = 'impact';
        icon1 = '🕵️‍♂️'; icon2 = '🚨'; icon3 = '👮‍♂️';
        exEng = 'The police caught the $low quickly.';
        exBng = 'পুলিশ দ্রুত $shortBng-টিকে ধরে ফেলেছে।';
        step1 = '১. গোপন তৎপরতা 🕵️‍♂️';
        step2 = '২. শনাক্ত: $clean ($shortBng) 🚨';
        step3 = '৩. আইনের হাতে আটক 👮‍♂️';
      } else if (hasMatch(r'\b(disease|cough|fever|illness|sickness|infection|virus|pain|wound)\b|রোগ|কাশি|জ্বর|অসুখ|ব্যথা|ক্ষত')) {
        sceneType = 'impact';
        icon1 = '🤒'; icon2 = '💊'; icon3 = '🏥';
        exEng = 'Timely medical care can cure $low.';
        exBng = 'সময়মতো চিকিৎসায় $shortBng সেরে যায়।';
        step1 = '১. শারীরিক লক্ষণ 🤒';
        step2 = '২. সমস্যা: $clean ($shortBng) 💊';
        step3 = '৩. চিকিৎসা ও সুস্থতা 🏥';
      } else if (hasMatch(r'\b(treatment|medicine|cure|therapy|care|health|doctor|hospital)\b|চিকিৎসা|ওষুধ|যত্ন|স্বাস্থ্য|ডাক্তার|হাসপাতাল')) {
        sceneType = 'rise';
        icon1 = '🤒'; icon2 = '🩺'; icon3 = '😊';
        exEng = 'Proper $low helps a patient recover fast.';
        exBng = 'সঠিক $shortBng রোগীকে দ্রুত সুস্থ হতে সাহায্য করে।';
        step1 = '১. অসুস্থ রোগী 🤒';
        step2 = '২. সেবা: $clean ($shortBng) 🩺';
        step3 = '৩. পূর্ণ সুস্থতা 😊';
      } else if (hasMatch(r'\b(body|breath|blood|heart|brain|eye|hand|head|face|voice|skin|bone)\b|শরীর|শ্বাস|রক্ত|হৃদয়|চোখ|হাত|মাথা|গলা')) {
        sceneType = 'nature';
        icon1 = '🧍'; icon2 = '🫀'; icon3 = '💪';
        exEng = 'We should take care of our $low every day.';
        exBng = 'প্রতিদিন আমাদের নিজের $shortBng-এর যত্ন নেওয়া উচিত।';
        step1 = '১. মানবদেহ 🧍';
        step2 = '২. অঙ্গ/অংশ: $clean ($shortBng) 🫀';
        step3 = '৩. সুস্থ ও সচল দেহ 💪';
      } else if (hasMatch(r'\b(hut|house|home|room|cottage|building|palace|tent|shelter)\b|কুঁড়ে ঘর|ঘর|বাড়ি|কক্ষ|ভবন|আশ্রয়')) {
        sceneType = 'travel';
        icon1 = '🌾'; icon2 = '🛖'; icon3 = '🏡';
        exEng = 'They built a small $low near the village.';
        exBng = 'তারা গ্রামের পাশে একটি ছোট $shortBng তৈরি করেছে।';
        step1 = '১. জায়গা ও উপকরণ 🌾';
        step2 = '২. বাসস্থান: $clean ($shortBng) 🛖';
        step3 = '৩. নিরাপদ আশ্রয় 🏡';
      } else if (hasMatch(r'\b(village|country|city|town|field|ground|land|nation|state|market|road|street|bridge)\b|গ্রাম|দেশ|শহর|মাঠ|রাস্তা|বাজার|সেতু')) {
        sceneType = 'nature';
        icon1 = '🌳'; icon2 = '🏞️'; icon3 = '🌍';
        exEng = 'Our $low is very clean and peaceful.';
        exBng = 'আমাদের $shortBng খুব পরিষ্কার এবং শান্তিপূর্ণ।';
        step1 = '১. চারপাশের পরিবেশ 🌳';
        step2 = '২. স্থান: $clean ($shortBng) 🏞️';
        step3 = '৩. সুন্দর জনপদ 🌍';
      } else if (hasMatch(r'\b(people|neighbour|neighbor|relative|family|friend|expert|guest|citizen|person|man|woman|leader|worker)\b|মানুষ|প্রতিবেশী|আত্মীয়|পরিবার|বন্ধু|দক্ষ|মেহমান|নাগরিক')) {
        sceneType = 'exchange';
        icon1 = '🧑'; icon2 = '👨‍👩‍👧‍👦'; icon3 = '🤝';
        exEng = 'Good $low always support one another.';
        exBng = 'ভালো $shortBng সবসময় একে অপরকে সহযোগিতা করে।';
        step1 = '১. ব্যক্তি বা সদস্য 🧑';
        step2 = '২. পরিচয়: $clean ($shortBng) 👨‍👩‍👧‍👦';
        step3 = '৩. সামাজিক বন্ধন 🤝';
      } else if (hasMatch(r'\b(sweet|bread|crop|butter|nut|food|meal|rice|milk|fruit|sugar|salt|meat|fish|tea|oil)\b|মিষ্টি|রুটি|ফসল|মাখন|বাদাম|খাবার|ভাত|দুধ|ফল|চিনি|লবণ|মাংস|মাছ')) {
        sceneType = 'food';
        icon1 = '🌾'; icon2 = '🍲'; icon3 = '😋';
        exEng = 'Fresh $low is good for our health.';
        exBng = 'তাজা $shortBng আমাদের স্বাস্থ্যের জন্য ভালো।';
        step1 = '১. প্রাকৃতিক উৎস 🌾';
        step2 = '২. খাবার: $clean ($shortBng) 🍲';
        step3 = '৩. পুষ্টি ও তৃপ্তি 😋';
      } else if (hasMatch(r'\b(animal|bird|dog|cat|cow|horse|lion|tiger|insect|snake)\b|প্রাণী|পাখি|পশু|কুকুর|বিড়াল|গরু|ঘোড়া|সিংহ|বাঘ')) {
        sceneType = 'nature';
        icon1 = '🌿'; icon2 = '🐾'; icon3 = '🦁';
        exEng = 'Every $low plays an important role in nature.';
        exBng = 'প্রকৃতিতে প্রতিটি $shortBng-র গুরুত্বপূর্ণ ভূমিকা আছে।';
        step1 = '১. প্রাকৃতিক পরিবেশ 🌿';
        step2 = '২. জীব: $clean ($shortBng) 🐾';
        step3 = '৩. জীববৈচিত্র্য 🦁';
      } else if (hasMatch(r'\b(hill|mountain|earth|dust|river|sea|ocean|sky|sun|moon|star|rain|wind|forest|tree|flower|water|weather)\b|পাহাড়|পৃথিবী|ধুলো|নদী|সমুদ্র|আকাশ|সূর্য|চাঁদ|বৃষ্টি|বাতাস|বন|গাছ|ফুল|পানি|আবহাওয়া')) {
        sceneType = 'nature';
        icon1 = '🌤️'; icon2 = '⛰️'; icon3 = '🌍';
        exEng = 'We can see the beauty of $low in nature.';
        exBng = 'আমরা প্রকৃতিতে $shortBng-র সৌন্দর্য দেখতে পাই।';
        step1 = '১. প্রকৃতির রূপ 🌤️';
        step2 = '২. উপাদান: $clean ($shortBng) ⛰️';
        step3 = '৩. সুন্দর পৃথিবী 🌍';
      } else if (hasMatch(r'\b(amount|distance|division|capacity|day|time|end|edge|number|price|cost|money|weight|size|speed|rate|part|hour|week|month|year)\b|পরিমাণ|দূরত্ব|বিভাগ|ক্ষমতা|দিন|সময়|শেষ|প্রান্ত|টাকা|মূল্য|ওজন|আকার|গতি|অংশ|সপ্তাহ|মাস|বছর')) {
        sceneType = 'scale';
        icon1 = '⚖️'; icon2 = '📊'; icon3 = '🎯';
        exEng = 'Please check the exact $low carefully.';
        exBng = 'অনুগ্রহ করে সঠিক $shortBng ভালোভাবে যাচাই করুন।';
        step1 = '১. মাপ বা গণনা শুরু ⚖️';
        step2 = '২. পরিমাপ: $clean ($shortBng) 📊';
        step3 = '৩. নির্ভুল ফলাফল 🎯';
      } else if (hasMatch(r'\b(mystery|doubt|secret|puzzle|question|problem|riddle)\b|রহস্য|সন্দেহ|গোপন|প্রশ্ন|সমস্যা')) {
        sceneType = 'vision';
        icon1 = '🔍'; icon2 = '❓'; icon3 = '💡';
        exEng = 'We finally solved the $low together.';
        exBng = 'আমরা অবশেষে একসাথে $shortBng-টির সমাধান করেছি।';
        step1 = '১. অজানা বিষয় 🔍';
        step2 = '২. অনুসন্ধান: $clean ($shortBng) ❓';
        step3 = '৩. সঠিক সমাধান 💡';
      } else if (hasMatch(r'\b(anger|cry|fear|sorrow|grief|shame|hatred|worry|anxiety|death)\b|রাগ|কান্না|ভয়|দুঃখ|লজ্জা|ঘৃণা|চিন্তা|মৃত্যু')) {
        sceneType = 'communicate';
        icon1 = '😟'; icon2 = '🧘'; icon3 = '🌤️';
        exEng = 'We should overcome $low with patience.';
        exBng = 'ধৈর্যের সাথে আমাদের $shortBng জয় করা উচিত।';
        step1 = '১. কঠিন অনুভূতি 😟';
        step2 = '২. অবস্থা: $clean ($shortBng) 💭';
        step3 = '৩. ধৈর্য ও প্রশান্তি 🌤️';
      } else if (hasMatch(r'\b(law|crime|danger|damage|error|fault|fight|war|punishment|rule|control|evidence|fire)\b|আইন|অপরাধ|বিপদ|ক্ষতি|ভুল|লড়াই|যুদ্ধ|শাস্তি|নিয়ন্ত্রণ|প্রমাণ|আগুন')) {
        sceneType = 'impact';
        icon1 = '⚠️'; icon2 = '⚖️'; icon3 = '🛡️';
        exEng = 'Everyone must stay careful about $low.';
        exBng = 'সবারই $shortBng সম্পর্কে সতর্ক থাকা জরুরি।';
        step1 = '১. সতর্কতা ও নিয়ম ⚠️';
        step2 = '২. বিষয়: $clean ($shortBng) ⚖️';
        step3 = '৩. নিরাপত্তা ও শৃঙ্খলা 🛡️';
      } else if (hasMatch(r'\b(information|attention|belief|decision|design|detail|development|discovery|discussion|education|example|cause|effect|idea|knowledge|plan|reason|memory|mind)\b|তথ্য|মনোযোগ|বিশ্বাস|সিদ্ধান্ত|নকশা|বিস্তারিত|উন্নয়ন|আবিষ্কার|আলোচনা|শিক্ষা|উদাহরণ|কারণ|প্রভাব|ধারণা|জ্ঞান|পরিকল্পনা')) {
        sceneType = 'study';
        icon1 = '📖'; icon2 = '🧠'; icon3 = '💡';
        exEng = 'Good $low helps us move forward in life.';
        exBng = 'ভালো $shortBng আমাদের জীবনে এগিয়ে যেতে সাহায্য করে।';
        step1 = '১. চিন্তা ও শিক্ষা 📖';
        step2 = '২. বিষয়: $clean ($shortBng) 🧠';
        step3 = '৩. বাস্তব সাফল্য 💡';
      } else if (hasMatch(r'\b(desk|table|chair|bed|clothes|dress|shirt|shoe|bag|box|book|pen|phone|computer|car|bus|train|flight|boat|tool|machine)\b|টেবিল|চেয়ার|কাপড়|পোশাক|ব্যাগ|বাক্স|বই|কলম|গাড়ি|ফ্লাইট|নৌকা|যন্ত্র')) {
        sceneType = 'exchange';
        icon1 = '🛠️'; icon2 = '📦'; icon3 = '✨';
        exEng = 'Please keep the $low in the right place.';
        exBng = 'অনুগ্রহ করে $shortBng-টি সঠিক জায়গায় রাখুন।';
        step1 = '১. প্রয়োজনীয় বস্তু 🛠️';
        step2 = '২. উপকরণ: $clean ($shortBng) 📦';
        step3 = '৩. দৈনন্দিন ব্যবহার ✨';
      } else {
        sceneType = 'communicate';
        icon1 = '🌿'; icon2 = '😊'; icon3 = '🌟';
        exEng = 'Everyone values $low in daily life.';
        exBng = 'দৈনন্দিন জীবনে সবাই $shortBng-কে গুরুত্ব দেয়।';
        step1 = '১. জীবনযাত্রার অংশ 🌿';
        step2 = '২. ধারণা: $clean ($shortBng) 😊';
        step3 = '৩. ইতিবাচক প্রভাব 🌟';
      }
    } else if (isAdj) {
      if (hasMatch(r'\b(sick|ill|weak|poor|hungry|tired|helpless|blind|deaf)\b|অসুস্থ|দুর্বল|দরিদ্র|বেচারা|ক্ষুধার্ত|ক্লান্ত|অসহায়')) {
        sceneType = 'exchange';
        icon1 = '🤒'; icon2 = '🤝'; icon3 = '❤️';
        exEng = 'We should always help a $low person.';
        exBng = 'একজন $shortBng মানুষকে আমাদের সবসময় সাহায্য করা উচিত।';
        step1 = '১. সহায়তা প্রয়োজন 🤒';
        step2 = '২. অবস্থা: $clean ($shortBng) 🤝';
        step3 = '৩. মানবিক সহানুভূতি ❤️';
      } else if (hasMatch(r'\b(bad|worse|worst|selfish|cruel|lazy|dishonest|wrong|false|dangerous|dirty|angry|greedy)\b|খারাপ|স্বার্থপর|নিষ্ঠুর|অলস|অসৎ|ভুল|মিথ্যা|বিপদজনক|নোংরা|লোভী')) {
        sceneType = 'impact';
        icon1 = '🚫'; icon2 = '🔄'; icon3 = '✅';
        exEng = 'We must avoid any $low habit in life.';
        exBng = 'জীবনে যেকোনো $shortBng অভ্যাস আমাদের বর্জন করা উচিত।';
        step1 = '১. নেতিবাচক গুণ 🚫';
        step2 = '২. সতর্কতা: $clean ($shortBng) 🔄';
        step3 = '৩. সঠিক পথে ফেরা ✅';
      } else {
        sceneType = 'scale';
        icon1 = '🔹'; icon2 = '🌟'; icon3 = '🏆';
        exEng = 'Being $low is a very helpful quality.';
        exBng = '$shortBng হওয়া একটি অত্যন্ত চমৎকার গুণ।';
        step1 = '১. সাধারণ মাত্রা 🔹';
        step2 = '২. বিশেষ গুণ: $clean ($shortBng) 🌟';
        step3 = '৩. সেরা অবস্থান 🏆';
      }
    } else if (isAdv) {
      sceneType = 'timeline';
      if (hasMatch(r'\b(always|daily|every day)\b|সবসময়|দৈনিক|প্রতিদিন')) {
        freqDays = 7;
      } else if (hasMatch(r'\b(usually|normally|generally|often|frequently)\b|প্রায়ই|সাধারণত|অনেকবার')) {
        freqDays = 5;
      } else if (hasMatch(r'\b(sometimes|occasionally|occasion|weekly|monthly|yearly)\b|মাঝে মাঝে|সপ্তাহে|মাসে|বছরে')) {
        freqDays = 3;
      } else if (hasMatch(r'\b(seldom|hardly|rarely)\b|বিরল|খুব কমই')) {
        freqDays = 1;
      } else if (hasMatch(r'\b(never)\b|কখনোই না')) {
        freqDays = 0;
      } else {
        freqDays = 6;
      }
      icon1 = '📅'; icon2 = '⏱️'; icon3 = '✅';
      if (freqDays <= 1) {
        exEng = 'A sincere student $low wastes time.';
        exBng = 'একজন মনোযোগী শিক্ষার্থী $shortBng সময় নষ্ট করে।';
      } else if (hasMatch(r'\b(easily|gladly|gently|quietly|safely|truthfully|carefully|quickly|slowly|well|fast)\b|সহজে|আনন্দে|আলতো|শান্তভাবে|নিরাপদে|সত্যই|সাবধানে|দ্রুত|ধীরে')) {
        exEng = 'She completed the work $low.';
        exBng = 'সে $shortBng কাজটি সম্পন্ন করেছে।';
      } else {
        exEng = 'We practice English $low to improve.';
        exBng = 'দক্ষতা বাড়াতে আমরা $shortBng ইংরেজি চর্চা করি।';
      }
      step1 = '১. কাজের শুরু 📅';
      step2 = '২. ধরন/সময়: $clean ($shortBng) ⏱️';
      step3 = '৩. কাজের ফলাফল ✅';
    } else {
      // VERB MATCHING WITH STRICT WORD BOUNDARIES
      if (hasMatch(r'\b(go|walk|run|move|come|reach|leave|travel|follow|enter|escape|pass|step|advance|return|arrive|drive|ride|overtake)\b|যাত্রা|যাওয়া|আসা|হাঁটা|দৌড়|পৌঁছা|চলা|ফিরে|চালানো')) {
        sceneType = 'travel'; icon1 = '🏠'; icon2 = '🏃‍♂️'; icon3 = '🏁';
      } else if (hasMatch(r'\b(swim|dive|sink|float|wash|sail|flow|bath|bathe)\b|সাঁতার|ডুব|ভেসে|ধোয়া|গোসল')) {
        sceneType = 'water'; icon1 = '🌊'; icon2 = '🏊‍♂️'; icon3 = '🏝️';
      } else if (hasMatch(r'\b(fly|rise|grow|jump|climb|increase|improve|wake|build|stand)\b|উঠা|ওড়া|বড় হওয়া|বৃদ্ধি|উন্নতি|জাগা|তৈরি')) {
        sceneType = 'rise'; icon1 = '🌱'; icon2 = '🚀'; icon3 = '☀️';
      } else if (hasMatch(r'\b(fall|drop|slip|decrease|lose|shrink|die|lie|sit)\b|পড়া|পড়ে যাওয়া|কমে|মরা|ছোট হয়ে|বসা|শোয়া')) {
        sceneType = 'fall'; icon1 = '☁️'; icon2 = '🍂'; icon3 = '⬇️';
      } else if (hasMatch(r'\b(give|take|send|get|buy|sell|pay|bring|lend|borrow|offer|donate|receive|pick|steal|withdraw|help|share)\b|দেওয়া|নেওয়া|পাওয়া|কেনা|বিক্রি|টাকা|তোলা|সাহায্য|ভাগ')) {
        sceneType = 'exchange'; icon1 = '🧑'; icon2 = '🎁'; icon3 = '👩';
      } else if (hasMatch(r'\b(speak|say|tell|ask|call|sing|talk|cry|laugh|smile|shout|greet|thank|excuse|forgive|swear|forbid|cough|answer|discuss)\b|বলা|কথা|গান|ডাকা|হাসা|কাঁদা|ক্ষমা|কাশি|উত্তর')) {
        sceneType = 'communicate'; icon1 = '🗣️'; icon2 = '💬'; icon3 = '😊';
      } else if (hasMatch(r'\b(see|look|watch|find|search|hide|show|appear|view|oversee|notice|observe)\b|দেখা|খোঁজা|লুকানো|প্রকাশ')) {
        sceneType = 'vision'; icon1 = '👀'; icon2 = '🔍'; icon3 = '✨';
      } else if (hasMatch(r'\b(break|cut|tear|hit|beat|fight|destroy|damage|hamper|bite|attack|kill)\b|ভাঙ্গা|কাটা|ছিঁড়ে|মারা|ক্ষতি|কামড়|আক্রমণ')) {
        sceneType = 'impact'; icon1 = '⚡'; icon2 = '💥'; icon3 = '🛡️';
      } else if (hasMatch(r'\b(eat|drink|cook|feed|taste|chew|swallow)\b|খাওয়া|পান করা|রান্না|চিবানো')) {
        sceneType = 'food'; icon1 = '🌾'; icon2 = '🍲'; icon3 = '😋';
      } else {
        sceneType = 'study'; icon1 = '📖'; icon2 = '✍️'; icon3 = '💡';
      }

      final rawPhrase = w.eng.replaceAll(RegExp(r'\((.*?)\)'), r'$1').split('/')[0].trim().toLowerCase();
      if (w.bng.contains('করা') || w.bng.contains('দেওয়া') || w.bng.contains('নেওয়া')) {
        exEng = 'We should $rawPhrase our work properly.';
        exBng = 'আমাদের কাজটি সঠিকভাবে $shortBng উচিত।';
      } else if (w.bng.contains('হওয়া') || w.bng.contains('যাওয়া') || w.bng.contains('আসা')) {
        exEng = 'They can $rawPhrase on time every day.';
        exBng = 'তারা প্রতিদিন সময়মতো $shortBng পারে।';
      } else {
        exEng = 'Always try to $rawPhrase carefully.';
        exBng = 'সবসময় মনোযোগ দিয়ে $shortBng চেষ্টা করো।';
      }
      step1 = '১. কে করছে? (Subject 👤)';
      step2 = '২. কাজ: $clean ($shortBng) ⚡';
      step3 = '৩. ফলাফল: কাজটি সম্পন্ন হলো 🎯';
    }

    return {
      'sceneType': sceneType,
      'icon1': icon1,
      'icon2': icon2,
      'icon3': icon3,
      'freqDays': '$freqDays',
      'exEng': exEng,
      'exBng': exBng,
      'step1': step1,
      'step2': step2,
      'step3': step3,
      'clean': clean,
      'shortBng': shortBng,
    };
  }

  // ===========================================================================
  // LOCK / UNLOCK & HARD DISCIPLINE LOGIC
  // ===========================================================================
  String _groupKey() => _activeKeys.join('_');
  String _setCompletionKey(int setIdx) => '${_groupKey()}_${_batchSize}_$setIdx';
  String _revPassKey(int revGroup) => '${_groupKey()}_${_batchSize}_rev_$revGroup';

  bool _isSetUnlocked(int setIdx) {
    if (setIdx == 0) return true;
    if (_completedSets[_setCompletionKey(setIdx - 1)] != true) return false;
    final completedBlocks = setIdx ~/ 3;
    for (int g = 0; g < completedBlocks; g++) {
      final s1 = _completedSets[_setCompletionKey(g * 3)] == true;
      final s2 = _completedSets[_setCompletionKey(g * 3 + 1)] == true;
      final s3 = _completedSets[_setCompletionKey(g * 3 + 2)] == true;
      if (s1 && s2 && s3 && _passedRevisions[_revPassKey(g)] != true) {
        return false;
      }
    }
    return true;
  }

  int _pendingMandatoryRevisionGroup() {
    if (_categoryFullWords.isEmpty) return -1;
    final totalSets = (_categoryFullWords.length / _batchSize).ceil();
    final totalBlocks = totalSets ~/ 3;
    for (int g = 0; g < totalBlocks; g++) {
      final s1 = _completedSets[_setCompletionKey(g * 3)] == true;
      final s2 = _completedSets[_setCompletionKey(g * 3 + 1)] == true;
      final s3 = _completedSets[_setCompletionKey(g * 3 + 2)] == true;
      if (s1 && s2 && s3 && _passedRevisions[_revPassKey(g)] != true) {
        return g;
      }
    }
    return -1;
  }

  int _findNextUnlockedSetIndex() {
    if (_categoryFullWords.isEmpty) return 0;
    final totalSets = (_categoryFullWords.length / _batchSize).ceil();
    int nextIdx = 0;
    for (int sIdx = 0; sIdx < totalSets; sIdx++) {
      if (_completedSets[_setCompletionKey(sIdx)] == true) {
        nextIdx = min(totalSets - 1, sIdx + 1);
      } else {
        break;
      }
    }
    return nextIdx;
  }

  void _openSetMapForKeys(List<String> keys, String title) {
    final full = <VocabWord>[];
    for (final k in keys) {
      if (_vocabDb[k] != null) full.addAll(_vocabDb[k]!);
    }
    setState(() {
      _activeKeys = keys;
      _activeTitle = title;
      _categoryFullWords = full;
      _currentSetIndex = _findNextUnlockedSetIndex();
      _screen = 'set_map';
    });
    _saveLocalProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_setMapScrollController.hasClients && _currentSetIndex > 1) {
        final targetOffset = max(0.0, (_currentSetIndex - 1) * 76.0);
        _setMapScrollController.animateTo(
          min(targetOffset, _setMapScrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _resumeSavedLastSession() {
    final sess = _lastSession ?? _deriveSessionFromCompletedSets();
    if (sess == null) return;
    final cat = (sess['currentCategory'] ?? 'noun').toString();
    final rawKeys = sess['activeKeys'];
    final keys = (rawKeys is List && rawKeys.isNotEmpty)
        ? rawKeys.map((e) => e.toString()).toList()
        : [cat == 'verb' ? 'page1' : cat];
    final title = (sess['activeTitleLabel'] ?? '${cat.toUpperCase()} এর শব্দসমূহ').toString();
    _currentCategory = cat;
    _openSetMapForKeys(keys, title);
    final nextSet = _findNextUnlockedSetIndex();
    final savedSet = int.tryParse((sess['currentSetIndex'] ?? nextSet).toString()) ?? nextSet;
    final targetSet = max(nextSet, savedSet);
    if (_isSetUnlocked(targetSet)) {
      _startSet(targetSet);
    }
  }

  void _startSet(int setIdx) {
    if (_hardWords.length >= _adminMistakeLimit &&
        _completedSets[_setCompletionKey(setIdx)] != true) {
      HapticFeedback.heavyImpact();
      _showSnack(
          '🚨 মিস্টেক জেল! $_adminMistakeLimitটি ভুল শব্দ জমে গেছে! নতুন সেটের আগে ভুল শব্দগুলো ক্লিয়ার করুন!',
          isError: true);
      _startHardWordsPractice();
      return;
    }
    if (!_isSetUnlocked(setIdx)) {
      HapticFeedback.mediumImpact();
      _showSnack('🔒 এই সেটটি লক করা! আগে আগের সেট ও বাধ্যতামূলক রিভিশন শেষ করুন!',
          isError: true);
      return;
    }
    final start = setIdx * _batchSize;
    final end = min(_categoryFullWords.length, (setIdx + 1) * _batchSize);
    setState(() {
      _isRevisionSession = false;
      _activeRevisionGroup = -1;
      _currentSetIndex = setIdx;
      _wordsArray = _categoryFullWords.sublist(start, end);
      _currentWordIndex = 0;
      _guidedStep = 1;
      _maxUnlockedGuidedStep = _completedSets[_setCompletionKey(setIdx)] == true ? 4 : 1;
      _seenInStep1 = {0};
      _sessionHearts = _adminMaxHearts;
      _screen = 'practice';
    });
    _prepareCurrentStepState();
    _syncProgressToServer();
  }

  void _startMandatoryRevision(int revGroup) {
    final start = revGroup * 3 * _batchSize;
    final end = min(_categoryFullWords.length, (revGroup + 1) * 3 * _batchSize);
    final pool = _categoryFullWords.sublist(start, end)..shuffle();
    setState(() {
      _isRevisionSession = true;
      _activeRevisionGroup = revGroup;
      _wordsArray = pool.take(min(12, pool.length)).toList();
      _currentWordIndex = 0;
      _currentMode = 'guided';
      _guidedStep = 2;
      _maxUnlockedGuidedStep = 2;
      _sessionHearts = _adminMaxHearts;
      _screen = 'practice';
    });
    _prepareCurrentStepState();
    _showSnack('🚨 বাধ্যতামূলক রিভিশন শুরু হয়েছে! পাস করলেই পরের সেট খুলবে।');
  }

  void _startHardWordsPractice() {
    if (_hardWords.isEmpty) {
      _showSnack('🎉 আপনার কোনো কঠিন বা ভুল শব্দ জমা নেই!');
      return;
    }
    setState(() {
      _isRevisionSession = false;
      _currentCategory = 'hard';
      _activeTitle = '🔥 ভুল ও কঠিন শব্দের জেল (${_hardWords.length}টি)';
      _wordsArray = _hardWords
          .map((e) => VocabWord(eng: e['eng'] ?? '', bng: e['bng'] ?? '', sourceKey: 'hard'))
          .toList();
      _currentWordIndex = 0;
      _currentMode = 'guided';
      _guidedStep = 1;
      _maxUnlockedGuidedStep = 4;
      _seenInStep1 = {0};
      _sessionHearts = _adminMaxHearts;
      _screen = 'practice';
    });
    _prepareCurrentStepState();
  }

  void _startQuestionTimer(VoidCallback onTimeout) {
    _questionTimer?.cancel();
    setState(() => _questionTimeLeft = _adminTimerSeconds);
    _questionTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_questionTimeLeft <= 1) {
        t.cancel();
        onTimeout();
      } else {
        setState(() => _questionTimeLeft--);
      }
    });
  }

  bool _deductHeartAndCheckReset(String reason) {
    HapticFeedback.heavyImpact();
    _shakeController.forward(from: 0);
    setState(() => _sessionHearts = max(0, _sessionHearts - 1));
    if (_sessionHearts <= 0) {
      _questionTimer?.cancel();
      setState(() {
        _sessionHearts = _adminMaxHearts;
        _guidedStep = 1;
        _maxUnlockedGuidedStep = 1;
        _currentWordIndex = 0;
        _seenInStep1 = {0};
      });
      _prepareCurrentStepState();
      _showSnack(
          '💔 সব লাইফ শেষ! সেটটি আবার ১ম ধাপ (দেখা ও শোনা) থেকে শুরু হলো!',
          isError: true);
      return true;
    }
    _showSnack(reason, isError: true);
    return false;
  }

  void _prepareCurrentStepState() {
    _questionTimer?.cancel();
    if (_wordsArray.isEmpty) return;
    if (_currentWordIndex >= _wordsArray.length) _currentWordIndex = 0;
    final currentWord = _wordsArray[_currentWordIndex];
    _seenInStep1.add(_currentWordIndex);
    if (_seenInStep1.length >= _wordsArray.length && _maxUnlockedGuidedStep < 2) {
      _maxUnlockedGuidedStep = 2;
    }
    _usedHintOnCurrentWord = false;
    _flashcardFlipped = false;
    _noteController.text = _customNotes[currentWord.eng] ?? '';
    _triggerSequentialGlowAnimation();

    final effectiveMode = _currentMode == 'guided'
        ? (_guidedStep == 1
            ? 'step1'
            : (_guidedStep == 2 ? 'step2' : (_guidedStep == 3 ? 'mcq' : 'spelling')))
        : _currentMode;

    if (effectiveMode == 'step1' || effectiveMode == 'flashcard') {
      _speak(currentWord.eng, rate: 0.45);
    } else if (effectiveMode == 'step2') {
      final sub = _wordsArray.take(min(5, _wordsArray.length)).toList();
      _matchEngList = List<VocabWord>.from(sub)..shuffle();
      _matchBngList = List<VocabWord>.from(sub)..shuffle();
      _selectedMatchEng = null;
      _selectedMatchBng = null;
      _matchedWords.clear();
    } else if (effectiveMode == 'mcq') {
      final correct = _mcqEngToBng ? currentWord.bng : currentWord.eng;
      final pool = _categoryFullWords.length >= 4 ? _categoryFullWords : _wordsArray;
      final opts = <String>{correct};
      final rnd = Random();
      int tries = 0;
      while (opts.length < 4 && tries < 60 && pool.isNotEmpty) {
        final cand = pool[rnd.nextInt(pool.length)];
        opts.add(_mcqEngToBng ? cand.bng : cand.eng);
        tries++;
      }
      _mcqOptions = opts.toList()..shuffle();
      _mcqSelected = '';
      _mcqFeedback = '';
      if (_mcqEngToBng) _speak(currentWord.eng, rate: 0.45);
      _startQuestionTimer(() {
        _handleMcqAnswer('__TIMEOUT__');
      });
    } else if (effectiveMode == 'spelling') {
      final clean = _cleanPrimaryWord(currentWord.eng);
      _tilePool = clean.split('')..shuffle();
      _usedTileIndices.clear();
      _spellController.clear();
      _spellFeedback = '';
      _speak(currentWord.eng, rate: 0.42);
      _startQuestionTimer(() {
        _handleSpellingSubmit(isTimeout: true);
      });
    }
  }

  void _markWordHard(VocabWord w, {bool silent = false}) {
    if (!_hardWords.any((e) => e['eng'] == w.eng)) {
      setState(() {
        _hardWords.add({'eng': w.eng, 'bng': w.bng});
      });
      _syncProgressToServer();
    }
    if (!silent) _showSnack('⭐ "${w.eng}" কঠিন শব্দের তালিকায় যোগ হয়েছে!');
  }

  void _markWordMastered(VocabWord w, {bool silent = false}) {
    setState(() {
      if (!_masteredWords.contains(w.eng)) _masteredWords.add(w.eng);
      _hardWords.removeWhere((e) => e['eng'] == w.eng);
    });
    _syncProgressToServer();
    if (!silent) {
      _showSnack('✅ "${w.eng}" মুখস্থ তালিকায় যোগ হয়েছে!');
      _nextWord();
    }
  }

  void _nextWord() {
    if (_currentWordIndex < _wordsArray.length - 1) {
      setState(() => _currentWordIndex++);
      _prepareCurrentStepState();
    } else if (_currentMode == 'guided' && _guidedStep == 1) {
      setState(() {
        _maxUnlockedGuidedStep = max(_maxUnlockedGuidedStep, 2);
        _guidedStep = 2;
        _currentWordIndex = 0;
      });
      _prepareCurrentStepState();
    }
  }

  void _prevWord() {
    if (_currentWordIndex > 0) {
      setState(() => _currentWordIndex--);
      _prepareCurrentStepState();
    }
  }

  void _handleMcqAnswer(String selected) {
    if (_mcqSelected.isNotEmpty) return;
    _questionTimer?.cancel();
    final currentWord = _wordsArray[_currentWordIndex];
    final correct = _mcqEngToBng ? currentWord.bng : currentWord.eng;

    if (selected == correct) {
      HapticFeedback.lightImpact();
      setState(() {
        _mcqSelected = selected;
        _mcqFeedback = '✨ সঠিক উত্তর!';
      });
      _speak(currentWord.eng, rate: 0.48);
      Future.delayed(const Duration(milliseconds: 750), () {
        if (!mounted) return;
        if (_currentWordIndex < _wordsArray.length - 1) {
          setState(() => _currentWordIndex++);
          _prepareCurrentStepState();
        } else if (_currentMode == 'guided') {
          setState(() {
            _maxUnlockedGuidedStep = max(_maxUnlockedGuidedStep, 4);
            _guidedStep = 4;
            _currentWordIndex = 0;
          });
          _prepareCurrentStepState();
          _showSnack('🎉 কুইজ সম্পন্ন! ৪র্থ ধাপ (সহজ বানান) আনলক হয়েছে!');
        } else {
          _completeCurrentSet();
        }
      });
    } else {
      _markWordHard(currentWord, silent: true);
      _wordsArray.add(currentWord);
      if (_deductHeartAndCheckReset(
          selected == '__TIMEOUT__' ? '⏱️ সময় শেষ! ১টি লাইফ কমেছে!' : '💔 ভুল উত্তর! ১টি লাইফ কমেছে!')) {
        return;
      }
      setState(() {
        _mcqSelected = selected;
        _mcqFeedback = '❌ সঠিক উত্তর: $correct (পাস করতে শেষে আবার আসবে)';
      });
    }
  }

  void _handleSpellingSubmit({bool isTimeout = false}) {
    _questionTimer?.cancel();
    final currentWord = _wordsArray[_currentWordIndex];
    final cleanTarget = _cleanPrimaryWord(currentWord.eng).toLowerCase();
    final typed = _spellController.text.trim().toLowerCase();

    if (!isTimeout && (typed == cleanTarget || typed == currentWord.eng.toLowerCase().trim())) {
      HapticFeedback.lightImpact();
      if (_usedHintOnCurrentWord) {
        _wordsArray.add(currentWord);
        setState(() {
          _spellFeedback = '💡 সঠিক, তবে হিন্ট নেওয়ার কারণে না দেখে পারার জন্য শেষে আবার আসবে!';
        });
      } else {
        _markWordMastered(currentWord, silent: true);
        setState(() {
          _spellFeedback = '✨ দারুণ! সঠিক বানান: ${currentWord.eng}';
        });
      }
      _speak(currentWord.eng, rate: 0.48);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        if (_currentWordIndex < _wordsArray.length - 1) {
          setState(() => _currentWordIndex++);
          _prepareCurrentStepState();
        } else {
          _completeCurrentSet();
        }
      });
    } else {
      _markWordHard(currentWord, silent: true);
      _wordsArray.add(currentWord);
      if (_deductHeartAndCheckReset(
          isTimeout ? '⏱️ সময় শেষ! ১টি লাইফ কমেছে!' : '💔 ভুল বানান! ১টি লাইফ কমেছে!')) {
        return;
      }
      setState(() {
        _spellFeedback = '❌ সঠিক বানান: ${_cleanPrimaryWord(currentWord.eng)} (শেষে আবার আসবে)';
      });
    }
  }

  void _completeCurrentSet() {
    _questionTimer?.cancel();
    HapticFeedback.mediumImpact();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_lastStudyDate != today) {
      _streakDays += 1;
      _lastStudyDate = today;
    }
    if (_isRevisionSession && _activeRevisionGroup >= 0) {
      _passedRevisions[_revPassKey(_activeRevisionGroup)] = true;
      _isRevisionSession = false;
      final nextSet = (_activeRevisionGroup + 1) * 3;
      _activeRevisionGroup = -1;
      _syncProgressToServer();
      _showSnack('🏆 বাধ্যতামূলক রিভিশন পাস! সেট ${nextSet + 1} আনলক হয়েছে!');
      setState(() => _screen = 'set_map');
      return;
    }
    _completedSets[_setCompletionKey(_currentSetIndex)] = true;
    _syncProgressToServer();
    _showSnack('🏆 অভিনন্দন! সেট ${_currentSetIndex + 1} সম্পন্ন ও পরের সেট আনলক হয়েছে!');
    setState(() => _screen = 'set_map');
  }

  // ===========================================================================
  // DIALOGS: UNIFIED LOGIN / REGISTER, USER PROFILE, AI TUTOR, MASTER ADMIN
  // ===========================================================================
  void _openAuthDialog({bool isRegister = false}) {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool registerMode = isRegister;
    String errText = '';
    bool busy = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset('assets/app_icon.png', width: 48, height: 48),
              ),
              const SizedBox(height: 8),
              Text(
                registerMode ? 'নতুন অ্যাকাউন্ট খুলুন' : 'Shohoj Vocab লগইন',
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
              const Text('Developed by Raz Ahamed',
                  style: TextStyle(fontSize: 11, color: Color(0xFF4F46E5))),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('🔑 লগইন'),
                        selected: !registerMode,
                        onSelected: (_) => setModalState(() {
                          registerMode = false;
                          errText = '';
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('✨ নতুন অ্যাকাউন্ট'),
                        selected: registerMode,
                        onSelected: (_) => setModalState(() {
                          registerMode = true;
                          errText = '';
                        }),
                      ),
                    ),
                  ],
                ),
                if (errText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(errText,
                        style: TextStyle(
                            color: Colors.red.shade800,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ইউজারনেম (Username)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'পাসওয়ার্ড (Password)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() => _screen = 'menu');
              },
              child: const Text('👤 গেস্ট মোডে চালিয়ে যান'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
              ),
              onPressed: busy
                  ? null
                  : () async {
                      final u = userCtrl.text.trim().toLowerCase();
                      final p = passCtrl.text.trim();
                      if (u.isEmpty || p.isEmpty) {
                        setModalState(() => errText = '❌ ইউজারনেম এবং পাসওয়ার্ড দিন!');
                        return;
                      }
                      setModalState(() {
                        busy = true;
                        errText = '';
                      });
                      try {
                        final endpoint =
                            registerMode ? '/api/auth/register' : '/api/auth/login';
                        final res = await http
                            .post(
                              Uri.parse('$kBaseApiUrl$endpoint'),
                              headers: {'Content-Type': 'application/json'},
                              body: jsonEncode({
                                'username': u,
                                'password': p,
                                'progress': _exportProgressPayload(),
                              }),
                            )
                            .timeout(const Duration(seconds: 10));
                        final data = jsonDecode(res.body);
                        if (data['ok'] != true) {
                          setModalState(() {
                            busy = false;
                            errText =
                                (data['error'] ?? '❌ আপনার ইউজারনেম বা পাসওয়ার্ডটি ভুল!')
                                    .toString();
                          });
                          return;
                        }
                        if (data['role'] == 'admin') {
                          setState(() {
                            _isMasterAdmin = true;
                            _username = (data['admin_username'] ?? 'admin').toString();
                            _authToken = (data['token'] ?? '').toString();
                          });
                          await _prefs?.setString('authToken', _authToken!);
                          await _prefs?.setString('username', _username!);
                          await _prefs?.setBool('isMasterAdmin', true);
                          if (mounted) Navigator.pop(ctx);
                          _openMasterAdminModal();
                          return;
                        }
                        final userObj = data['user'] ?? {};
                        setState(() {
                          _isMasterAdmin = false;
                          _username = (userObj['username'] ?? u).toString();
                          _authToken = (data['token'] ?? '').toString();
                          _screen = 'menu';
                        });
                        await _prefs?.setString('authToken', _authToken!);
                        await _prefs?.setString('username', _username!);
                        await _prefs?.setBool('isMasterAdmin', false);
                        _importProgressPayload(userObj['progress']);
                        if (mounted) Navigator.pop(ctx);
                        _showSnack('🎉 স্বাগতম $_username! আপনার অ্যাকাউন্ট সিঙ্ক হয়েছে।');
                      } catch (e) {
                        setModalState(() {
                          busy = false;
                          errText =
                              'সার্ভার কানেকশন পাওয়া যায়নি ($kBaseApiUrl)। ইন্টারনেট চেক করুন।';
                        });
                      }
                    },
              child: Text(busy
                  ? 'অপেক্ষা করুন...'
                  : (registerMode ? '✨ অ্যাকাউন্ট খুলুন' : '🔑 লগইন করুন')),
            ),
          ],
        ),
      ),
    );
  }

  void _openUserProfileModal() {
    final oldPassCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _username != null ? '👤 $_username' : '👤 গেস্ট ইউজার (Guest)',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  if (_username != null)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        await _syncProgressToServer();
                        setState(() {
                          _authToken = null;
                          _username = null;
                          _isMasterAdmin = false;
                          _masteredWords.clear();
                          _hardWords.clear();
                          _completedSets.clear();
                          _passedRevisions.clear();
                          _screen = 'landing';
                        });
                        await _prefs?.clear();
                        if (mounted) Navigator.pop(ctx);
                        _showSnack('👋 আপনি লগআউট হয়েছেন। আপনার ডাটা সার্ভারে সুরক্ষিত আছে!');
                      },
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text('লগআউট'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('✅ মুখস্থ: ${_masteredWords.length}টি')),
                  Chip(label: Text('🔥 ভুল জেল: ${_hardWords.length}/$_adminMistakeLimit')),
                  Chip(label: Text('🔓 সম্পন্ন সেট: ${_completedSets.length}টি')),
                  Chip(label: Text('🔥 স্ট্রিক: $_streakDays দিন')),
                ],
              ),
              if (_username != null && !_isMasterAdmin) ...[
                const Divider(height: 24),
                const Text('🔐 আপনার পাসওয়ার্ড পরিবর্তন করুন',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: oldPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          hintText: 'বর্তমান পাসওয়ার্ড',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: newPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          hintText: 'নতুন পাসওয়ার্ড',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      final res = await http.post(
                        Uri.parse('$kBaseApiUrl/api/auth/change-password'),
                        headers: _apiHeaders(),
                        body: jsonEncode({
                          'old_password': oldPassCtrl.text.trim(),
                          'new_password': newPassCtrl.text.trim(),
                        }),
                      );
                      final d = jsonDecode(res.body);
                      if (d['ok'] == true) {
                        if (mounted) Navigator.pop(ctx);
                        _showSnack('✅ আপনার পাসওয়ার্ড সফলভাবে পরিবর্তন হয়েছে!');
                      } else {
                        _showSnack((d['error'] ?? 'ত্রুটি!').toString(), isError: true);
                      }
                    } catch (_) {}
                  },
                  child: const Text('✓ পাসওয়ার্ড আপডেট করুন'),
                ),
              ],
              const Divider(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🔄 ক্লাউড সিঙ্ক ও লেভেল পুনরুদ্ধার (আগের শেষ করা সেট আনলক)',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text('আপনার আগে শেষ করা Noun বা অন্য ক্যাটাগরির সেট ১ ক্লিকে আনলক ও ওয়েবসাইটে সিঙ্ক করুন:',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final preset in [
                          {'k': 'noun', 'n': 6, 'label': '📦 Noun সেট ১–৬ আনলক'},
                          {'k': 'noun', 'n': 10, 'label': '📦 Noun সেট ১–১০ আনলক'},
                          {'k': 'page1', 'n': 6, 'label': '⚡ Verb P1 সেট ১–৬'},
                        ])
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal.shade700,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(0, 32),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            ),
                            onPressed: () async {
                              final ck = preset['k'] as String;
                              final upTo = preset['n'] as int;
                              setState(() {
                                for (int i = 0; i < upTo; i++) {
                                  _completedSets['${ck}_5_$i'] = true;
                                  if ((i + 1) % 3 == 0) {
                                    _passedRevisions['${ck}_5_rev_${i ~/ 3}'] = true;
                                  }
                                }
                                _currentCategory = ck.startsWith('page') ? 'verb' : ck;
                              });
                              _openSetMapForKeys(
                                [ck],
                                ck.startsWith('page') ? 'Verb Page 1' : '${ck.toUpperCase()} এর শব্দসমূহ',
                              );
                              await _syncProgressToServer();
                              if (mounted) Navigator.pop(ctx);
                              _showSnack('✅ সেট ১ থেকে $upTo আনলক ও ক্লাউডে সিঙ্ক হয়েছে! এখন সেট ${upTo + 1} থেকে শুরু করুন।');
                            },
                            child: Text(preset['label'] as String, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),
              const Text('🏆 সেরা নিয়মিত শিক্ষার্থী (Top Leaderboard)',
                  style: TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              if (_leaderboard.isEmpty)
                const Text('লিডারবোর্ড লোড হচ্ছে...', style: TextStyle(fontSize: 12))
              else
                ..._leaderboard.take(8).toList().asMap().entries.map((entry) {
                  final idx = entry.key;
                  final u = entry.value;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.amber.shade100,
                      child: Text('#${idx + 1}',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    title: Text('${u['username']} (${u['current_level'] ?? 'Set 1'})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    trailing: Text(
                      '✓ ${u['mastered_count'] ?? 0} • 🔥 ${u['streak_days'] ?? 1}d',
                      style: const TextStyle(
                          color: Colors.teal, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  void _openAiTutorSheet(VocabWord word) {
    final sentCtrl = TextEditingController();
    String aiReply =
        '✨ "${word.eng}" (${word.bng}) শব্দটি মনে রাখার কৌশল জানতে বা নিজের বাক্য যাচাই করতে নিচের বাটনে ট্যাপ করুন!';
    bool loading = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('✨ Gemini AI টিউটর — ${word.eng} (${word.bng})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(loading ? '🤖 Gemini AI চিন্তা করছে...' : aiReply,
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: sentCtrl,
                decoration: const InputDecoration(
                  hintText: 'এই শব্দটি দিয়ে একটি ইংরেজি বাক্য লিখুন...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: loading
                          ? null
                          : () async {
                              setSheetState(() => loading = true);
                              try {
                                final res = await http.post(
                                  Uri.parse('$kBaseApiUrl/api/ai/ask'),
                                  headers: _apiHeaders(),
                                  body: jsonEncode({
                                    'word': word.eng,
                                    'meaning': word.bng,
                                    'mode': 'mnemonic',
                                  }),
                                );
                                final d = jsonDecode(res.body);
                                setSheetState(() {
                                  loading = false;
                                  aiReply = (d['reply'] ??
                                          '💡 মনে রাখার কৌশল: ${word.eng} (${word.bng}) শব্দটি আজ ৩ বার বাস্তব জীবনে ব্যবহার করুন!')
                                      .toString();
                                });
                              } catch (_) {
                                setSheetState(() {
                                  loading = false;
                                  aiReply =
                                      '💡 মনে রাখার কৌশল: ${word.eng} অর্থ "${word.bng}" — উচ্চারণ শুনে ৩ বার খাতায় লিখুন!';
                                });
                              }
                            },
                      child: const Text('💡 মনে রাখার কৌশল'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: loading
                          ? null
                          : () async {
                              if (sentCtrl.text.trim().isEmpty) return;
                              setSheetState(() => loading = true);
                              try {
                                final res = await http.post(
                                  Uri.parse('$kBaseApiUrl/api/ai/ask'),
                                  headers: _apiHeaders(),
                                  body: jsonEncode({
                                    'word': word.eng,
                                    'meaning': word.bng,
                                    'sentence': sentCtrl.text.trim(),
                                    'mode': 'check_sentence',
                                  }),
                                );
                                final d = jsonDecode(res.body);
                                setSheetState(() {
                                  loading = false;
                                  aiReply = (d['reply'] ?? '✅ বাক্যটি যাচাই সম্পন্ন হয়েছে!')
                                      .toString();
                                });
                              } catch (_) {
                                setSheetState(() {
                                  loading = false;
                                  aiReply = '✅ চমৎকার চেষ্টা! আপনার বাক্য: "${sentCtrl.text}"';
                                });
                              }
                            },
                      child: const Text('✓ বাক্য যাচাই করুন'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMasterAdminModal() async {
    List<dynamic> users = [];
    List<dynamic> keys = [];
    final keyCtrl = TextEditingController();
    final heartsCtrl = TextEditingController(text: '$_adminMaxHearts');
    final timerCtrl = TextEditingController(text: '$_adminTimerSeconds');
    final mistakeCtrl = TextEditingController(text: '$_adminMistakeLimit');
    final annCtrl = TextEditingController(text: _announcement);
    bool antiCheatVal = _adminAntiCheat;

    try {
      final res = await http.get(
        Uri.parse('$kBaseApiUrl/api/admin/overview'),
        headers: _apiHeaders(),
      );
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        if (d['ok'] == true) {
          users = (d['users'] as List?) ?? [];
          keys = (d['gemini_keys'] as List?) ?? [];
          if (d['max_hearts'] != null) heartsCtrl.text = d['max_hearts'].toString();
          if (d['timer_seconds'] != null) timerCtrl.text = d['timer_seconds'].toString();
          if (d['mistake_limit'] != null) mistakeCtrl.text = d['mistake_limit'].toString();
          if (d['anti_cheat_enabled'] != null) antiCheatVal = d['anti_cheat_enabled'] == true;
          if (d['announcement'] != null) annCtrl.text = d['announcement'].toString();
        }
      }
    } catch (_) {}

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setAdmState) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          builder: (_, scrollCtrl) => ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('🛡️ MASTER ADMIN (Raz Ahamed)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _isMasterAdmin = false;
                        _authToken = null;
                        _username = null;
                      });
                      Navigator.pop(ctx);
                    },
                    child: const Text('🚪 অ্যাডমিন লগআউট'),
                  ),
                ],
              ),
              const Divider(),

              // REMOTE GAME RULES CONTROL CARD
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.indigo.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🎮 হার্ড মোড রুলস কন্ট্রোল (কোড ছাড়াই লাইফ ও টাইমার পরিবর্তন)',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: heartsCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '❤️ মোট লাইফ',
                              border: OutlineInputBorder(),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: timerCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '⏱️ টাইমার (Sec)',
                              border: OutlineInputBorder(),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: mistakeCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '🚨 ভুল জেল সীমা',
                              border: OutlineInputBorder(),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('🛡️ অ্যাপ অ্যান্টি-চিট (অ্যাপ ছাড়লে ১টি লাইফ কাটবে)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      value: antiCheatVal,
                      onChanged: (v) => setAdmState(() => antiCheatVal = v),
                    ),
                    TextField(
                      controller: annCtrl,
                      decoration: const InputDecoration(
                        labelText: '📢 সকল ইউজারের জন্য নোটিশ (Announcement)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4F46E5),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          final h = int.tryParse(heartsCtrl.text.trim()) ?? 3;
                          final t = int.tryParse(timerCtrl.text.trim()) ?? 15;
                          final m = int.tryParse(mistakeCtrl.text.trim()) ?? 10;
                          await http.post(
                            Uri.parse('$kBaseApiUrl/api/admin/settings'),
                            headers: _apiHeaders(),
                            body: jsonEncode({
                              'max_hearts': h,
                              'timer_seconds': t,
                              'mistake_limit': m,
                              'anti_cheat_enabled': antiCheatVal,
                              'announcement': annCtrl.text.trim(),
                            }),
                          );
                          setState(() {
                            _adminMaxHearts = h;
                            _adminTimerSeconds = t;
                            _adminMistakeLimit = m;
                            _adminAntiCheat = antiCheatVal;
                            _sessionHearts = h;
                            _announcement = annCtrl.text.trim();
                          });
                          if (mounted) Navigator.pop(ctx);
                          _showSnack(
                              '✅ রুলস আপডেট হয়েছে! (❤️ $h লাইফ, ⏱️ ${t}s টাইমার, 🚨 $m জেল)');
                        },
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('💾 রুলস ও নোটিশ সেভ করুন (সাথে সাথে কার্যকর)'),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 24),
              Text('👥 সকল রেজিস্টার্ড ইউজার (${users.length} জন)',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...users.map((u) {
                final banned = u['is_banned'] == 1 || u['is_banned'] == true;
                return Card(
                  color: banned ? Colors.red.shade50 : Colors.white,
                  child: ListTile(
                    title: Text('👤 ${u['username']} • 📍 ${u['current_level'] ?? 'Set 1'}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text(
                        'মুখস্থ: ${u['mastered_count'] ?? 0} • ভুল: ${u['hard_count'] ?? 0} • স্ট্রিক: ${u['streak_days'] ?? 1}d'),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: banned ? Colors.green : Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        await http.post(
                          Uri.parse('$kBaseApiUrl/api/admin/user/ban'),
                          headers: _apiHeaders(),
                          body: jsonEncode({
                            'user_id': u['id'],
                            'is_banned': banned ? 0 : 1,
                          }),
                        );
                        if (mounted) Navigator.pop(ctx);
                        _openMasterAdminModal();
                      },
                      child: Text(banned ? 'Unban' : 'Ban'),
                    ),
                  ),
                );
              }),
              const Divider(height: 28),
              Text('🔑 Multiple Gemini API Keys (${keys.length}টি)',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: keyCtrl,
                      decoration: const InputDecoration(
                        hintText: 'AIzaSy... নতুন Gemini API Key পেস্ট করুন',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      if (keyCtrl.text.trim().isEmpty) return;
                      await http.post(
                        Uri.parse('$kBaseApiUrl/api/admin/gemini-keys/add'),
                        headers: _apiHeaders(),
                        body: jsonEncode({
                          'api_keys': keyCtrl.text.trim(),
                          'label': 'Mobile Admin Key',
                        }),
                      );
                      if (mounted) Navigator.pop(ctx);
                      _openMasterAdminModal();
                    },
                    child: const Text('➕ যুক্ত করুন'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // UI BUILDERS
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    if (_loadingDb) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(62),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/app_icon.png', width: 38, height: 38),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              const Text('Shohoj Vocab',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900, fontSize: 15)),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _username != null
                                      ? Colors.teal.shade50
                                      : Colors.amber.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _username != null ? '✓ $_username' : 'গেস্ট মোড',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: _username != null
                                        ? Colors.teal.shade900
                                        : Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Text('Developed by Raz Ahamed',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF4F46E5))),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _openUserProfileModal,
                        icon: const Icon(Icons.person_pin, color: Colors.teal),
                        tooltip: 'প্রোফাইল ও লিডারবোর্ড',
                      ),
                      if (_isMasterAdmin)
                        TextButton(
                          onPressed: _openMasterAdminModal,
                          child: const Text('🛡️ অ্যাডমিন',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        )
                      else if (_username == null) ...[
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4F46E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                          ),
                          onPressed: () => _openAuthDialog(isRegister: false),
                          child: const Text('🔑 লগইন', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                      if (_screen != 'landing' && _screen != 'menu')
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _questionTimer?.cancel();
                            setState(() => _screen = 'menu');
                          },
                          icon: const Icon(Icons.home, color: Colors.redAccent),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: _buildActiveScreen(),
        ),
      ),
    );
  }

  Widget _buildActiveScreen() {
    switch (_screen) {
      case 'landing':
        return _buildLandingScreen();
      case 'menu':
        return _buildMainMenuScreen();
      case 'category':
        return _buildCategoryScreen();
      case 'verb_pages':
        return _buildVerbPagesScreen();
      case 'set_map':
        return _buildSetMapScreen();
      case 'practice':
        return _buildPracticeScreen();
      default:
        return _buildLandingScreen();
    }
  }

  Widget _buildLandingScreen() {
    return ListView(
      children: [
        if (_announcement.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.shade700,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text('📢 $_announcement',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF3730A3), Color(0xFF5B21B6)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset('assets/app_icon.png', width: 52, height: 52),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.amber,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('🌟 Shohoj Vocab — Developed by Raz Ahamed',
                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'চলমান ছবি, 3D ফ্লিপ কার্ড ও AI টিউটরের সাহায্যে ২,৯৯২টি ইংরেজি শব্দ চিরতরে মনে রাখুন!',
                style: TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                '৫টি করে শব্দের সেট • $_adminMaxHeartsটি লাইফ (❤️) • $_adminTimerSeconds সেকেন্ড টাইমার • অ্যান্টি-চিট ফোকাস লক!',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => _openAuthDialog(isRegister: false),
                    child: const Text('🔑 লগইন করুন (Login)',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF3730A3),
                    ),
                    onPressed: () => _openAuthDialog(isRegister: true),
                    child: const Text('✨ নতুন অ্যাকাউন্ট (Sign Up)',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    onPressed: () => setState(() => _screen = 'menu'),
                    child: const Text('👤 গেস্ট হিসেবে শুরু করুন ➔'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMainMenuScreen() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final studiedToday = _lastStudyDate == today;

    final resumeSess = _lastSession ?? _deriveSessionFromCompletedSets();
    return ListView(
      children: [
        if (resumeSess != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF0F766E), Color(0xFF047857)]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('⏳ যেখানে ছিলেন সেখান থেকে শুরু করুন',
                          style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.w900)),
                      Text(
                        '${(resumeSess['activeTitleLabel'] ?? resumeSess['currentCategory'] ?? 'NOUN')} — সেট ${(int.tryParse((resumeSess['currentSetIndex'] ?? '0').toString()) ?? 0) + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: _resumeSavedLastSession,
                  child: const Text('চালিয়ে যান ➔', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                ),
              ],
            ),
          ),
        if (!studiedToday)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(
              children: [
                const Text('🔔', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ডেইলি রিমাইন্ডার: আপনার $_streakDays দিনের স্ট্রিক ধরে রাখতে আজ অন্তত ১টি সেট সম্পন্ন করুন!',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade900),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            _StatBox('মোট শব্দ', '২,৯৯২', Colors.indigo),
            const SizedBox(width: 6),
            _StatBox('মুখস্থ', '${_masteredWords.length}', Colors.teal),
            const SizedBox(width: 6),
            _StatBox('ভুল জেল', '${_hardWords.length}/$_adminMistakeLimit', Colors.redAccent),
            const SizedBox(width: 6),
            _StatBox('স্ট্রিক 🔥', '$_streakDays দিন', Colors.amber.shade800),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('⭐ সবচেয়ে কার্যকর হার্ড ডিসিপ্লিন মেথড',
                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 11)),
              const SizedBox(height: 4),
              const Text('🎯 ৫টি করে শব্দ শিখুন (৪ ধাপে আনলক মেথড)',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                'চলমান অ্যানিমেশন • $_adminMaxHeartsটি লাইফ ❤️ • $_adminTimerSeconds সেকেন্ড টাইমার ⏱️ • অ্যান্টি-চিট লক',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  setState(() {
                    _currentMode = 'guided';
                    _screen = 'category';
                  });
                },
                child: const Text('🚀 এখনই শুরু করুন',
                    style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text('অথবা আলাদা প্র্যাকটিস মোড বেছে নিন:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ModeButton('🃏 Flashcard', '3D ফ্লিপ কার্ড', () {
                setState(() {
                  _currentMode = 'flashcard';
                  _screen = 'category';
                });
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ModeButton('✅ MCQ Quiz', '${_adminTimerSeconds}s কুইজ', () {
                setState(() {
                  _currentMode = 'mcq';
                  _screen = 'category';
                });
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ModeButton('✍️ Spelling', 'অডিও ও বানান', () {
                setState(() {
                  _currentMode = 'spelling';
                  _screen = 'category';
                });
              }),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade50,
            foregroundColor: Colors.red.shade800,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: _startHardWordsPractice,
          icon: const Icon(Icons.local_fire_department),
          label: Text(
              '🔥 Practice Hard/Mistake Words (${_hardWords.length}/$_adminMistakeLimit)',
              style: const TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }

  Widget _buildCategoryScreen() {
    return ListView(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('কোন ধরনের শব্দ শিখতে চান?',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            TextButton(
              onPressed: () => setState(() => _screen = 'menu'),
              child: const Text('← পেছনে যান'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _CategoryTile('⚡ Verb (ক্রিয়া / কাজ)', '২৬টি পেজ • ৭১৬টি শব্দ • ধাপে ধাপে আনলক', Colors.indigo, () {
          setState(() {
            _currentCategory = 'verb';
            _screen = 'verb_pages';
          });
        }),
        _CategoryTile('📦 Noun (বিশেষ্য / নাম)', '১,৪৫৮টি শব্দ • ৫টি করে লক/আনলক সেট', Colors.teal, () {
          _currentCategory = 'noun';
          _openSetMapForKeys(['noun'], 'NOUN এর শব্দসমূহ');
        }),
        _CategoryTile('🌟 Adjective (দোষ-গুণ)', '৫৩৫টি শব্দ • তুলনামূলক দৃশ্য ও রিভিশনসহ', Colors.amber.shade800, () {
          _currentCategory = 'adjective';
          _openSetMapForKeys(['adjective'], 'ADJECTIVE এর শব্দসমূহ');
        }),
        _CategoryTile('🚀 Adverb (ভাব-বিশেষণ)', '১৮৩টি শব্দ • টাইমলাইন ও বাধ্যতামূলক রিভিশনসহ', Colors.purple, () {
          _currentCategory = 'adverb';
          _openSetMapForKeys(['adverb'], 'ADVERB এর শব্দসমূহ');
        }),
      ],
    );
  }

  Widget _buildVerbPagesScreen() {
    final pageKeys = _vocabDb.keys.where((k) => k.startsWith('page')).toList()
      ..sort((a, b) =>
          int.parse(a.replaceAll('page', '')).compareTo(int.parse(b.replaceAll('page', ''))));

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('⚡ Verb Pages (১–২৬)',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            TextButton(
              onPressed: () => setState(() => _screen = 'category'),
              child: const Text('← পেছনে যান'),
            ),
          ],
        ),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 2.6,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: pageKeys.length,
            itemBuilder: (_, idx) {
              final k = pageKeys[idx];
              final pageNum = k.replaceAll('page', '');
              final count = _vocabDb[k]?.length ?? 0;
              return InkWell(
                onTap: () => _openSetMapForKeys([k], 'Verb Page $pageNum'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.indigo.shade100, width: 1.5),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Page $pageNum',
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
                          Text('$countটি শব্দ',
                              style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                      const Icon(Icons.play_circle_fill, color: Color(0xFF4F46E5)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSetMapScreen() {
    final totalSets = (_categoryFullWords.length / _batchSize).ceil();
    final pendingRev = _pendingMandatoryRevisionGroup();
    final nextUnlockedSet = _findNextUnlockedSetIndex();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('$_activeTitle (চলমান: সেট ${nextUnlockedSet + 1})',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  overflow: TextOverflow.ellipsis),
            ),
            TextButton(
              onPressed: () => setState(() => _screen = 'category'),
              child: const Text('← ক্যাটাগরি'),
            ),
          ],
        ),
        if (pendingRev < 0)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF0D9488)]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '🚀 আপনার চলমান লেভেল: সেট ${nextUnlockedSet + 1}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: () => _startSet(nextUnlockedSet),
                  child: Text('সেট ${nextUnlockedSet + 1} শুরু করুন ➔',
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                ),
              ],
            ),
          ),
        if (pendingRev >= 0)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Colors.redAccent, Colors.orange]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '🚨 বাধ্যতামূলক রিভিশন (সেট ${pendingRev * 3 + 1}–${pendingRev * 3 + 3}) বাকি আছে!',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => _startMandatoryRevision(pendingRev),
                  child: const Text('🎯 রিভিশন দিন'),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _setMapScrollController,
            itemCount: totalSets,
            itemBuilder: (_, s) {
              final start = s * _batchSize;
              final end = min(_categoryFullWords.length, (s + 1) * _batchSize);
              final slice = _categoryFullWords.sublist(start, end);
              final preview = slice.take(3).map((w) => _cleanPrimaryWord(w.eng)).join(', ');
              final isDone = _completedSets[_setCompletionKey(s)] == true;
              final unlocked = _isSetUnlocked(s);

              return Column(
                children: [
                  Card(
                    elevation: 0,
                    color: unlocked
                        ? (isDone ? Colors.teal.shade50 : Colors.white)
                        : Colors.grey.shade200,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: unlocked
                            ? (isDone ? Colors.teal : const Color(0xFF4F46E5))
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: ListTile(
                      onTap: () => _startSet(s),
                      leading: CircleAvatar(
                        backgroundColor: unlocked
                            ? (isDone ? Colors.teal : const Color(0xFF4F46E5))
                            : Colors.grey,
                        foregroundColor: Colors.white,
                        child: Text(isDone ? '✓' : (unlocked ? '${s + 1}' : '🔒')),
                      ),
                      title: Text(
                        unlocked ? 'সেট ${s + 1}: $preview...' : '🔒 সেট ${s + 1} (লক করা)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      subtitle: Text('শব্দ ${start + 1}–$end'),
                      trailing: Icon(unlocked ? Icons.play_arrow : Icons.lock, size: 20),
                    ),
                  ),
                  if ((s + 1) % 3 == 0)
                    Builder(builder: (_) {
                      final revGroup = s ~/ 3;
                      final revPassed = _passedRevisions[_revPassKey(revGroup)] == true;
                      final all3Done = _completedSets[_setCompletionKey(revGroup * 3)] == true &&
                          _completedSets[_setCompletionKey(revGroup * 3 + 1)] == true &&
                          _completedSets[_setCompletionKey(revGroup * 3 + 2)] == true;
                      return Card(
                        color: revPassed
                            ? Colors.amber.shade50
                            : (all3Done ? Colors.orange.shade600 : Colors.grey.shade100),
                        child: ListTile(
                          onTap: all3Done ? () => _startMandatoryRevision(revGroup) : null,
                          title: Text(
                            revPassed
                                ? '🏆 রিভিশন পাস! (সেট ${revGroup * 3 + 1}–${revGroup * 3 + 3})'
                                : '🚨 বাধ্যতামূলক রিভিশন (সেট ${revGroup * 3 + 1}–${revGroup * 3 + 3})',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                              color: all3Done && !revPassed ? Colors.white : Colors.black87,
                            ),
                          ),
                          trailing: Text(revPassed ? '✅' : (all3Done ? '🎯 শুরু' : '🔒')),
                        ),
                      );
                    }),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // PRACTICE SCREEN (WITH SHAKE ANIMATION, 3D FLIP FLASHCARD & RICH ANIMATIONS)
  // ===========================================================================
  Widget _buildPracticeScreen() {
    if (_wordsArray.isEmpty) return const SizedBox();
    final currentWord = _wordsArray[_currentWordIndex];
    final heartsStr = '❤️' * max(0, _sessionHearts) +
        '🖤' * max(0, _adminMaxHearts - _sessionHearts);

    final showTimer = (_currentMode == 'guided' && (_guidedStep == 3 || _guidedStep == 4)) ||
        _currentMode == 'mcq' ||
        _currentMode == 'spelling';

    return AnimatedBuilder(
      animation: _shakeController,
      builder: (_, child) {
        final dx = sin(_shakeController.value * pi * 4) * 10 * (1 - _shakeController.value);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Compact Top Practice Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('শব্দ: ${_currentWordIndex + 1}/${_wordsArray.length}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                                color: Color(0xFF4F46E5))),
                        const SizedBox(width: 8),
                        Text(heartsStr, style: const TextStyle(fontSize: 12)),
                        if (showTimer) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _questionTimeLeft <= 5
                                  ? Colors.red
                                  : Colors.amber.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '⏱️ ${_questionTimeLeft}s',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                                color: _questionTimeLeft <= 5
                                    ? Colors.white
                                    : Colors.amber.shade900,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () {
                        _questionTimer?.cancel();
                        setState(() => _screen = 'set_map');
                      },
                      icon: const Icon(Icons.list_alt, size: 15),
                      label: const Text('সেট লিস্ট', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                if (_currentMode == 'guided') ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _StepChip(1, '১. দেখুন'),
                      const SizedBox(width: 4),
                      _StepChip(2, '২. জোড়া'),
                      const SizedBox(width: 4),
                      _StepChip(3, '৩. কুইজ'),
                      const SizedBox(width: 4),
                      _StepChip(4, '৪. বানান'),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Main Workspace Area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _buildActivePracticeBody(currentWord),
            ),
          ),

          // Bottom Controls Bar (Hidden in Step 2 Match)
          if (!(_currentMode == 'guided' && _guidedStep == 2))
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey.shade200,
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: _prevWord,
                    child: const Text('⬅ আগেরটি',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade50,
                      foregroundColor: Colors.teal.shade800,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: () => _markWordMastered(currentWord),
                    child: const Text('✅ মুখস্থ',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade50,
                      foregroundColor: Colors.red.shade800,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: () => _markWordHard(currentWord),
                    child: const Text('⭐ কঠিন',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: _nextWord,
                    child: const Text('পরেরটি ➡',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _StepChip(int stepNum, String title) {
    final unlocked = stepNum <= _maxUnlockedGuidedStep;
    final active = _guidedStep == stepNum;
    return Expanded(
      child: InkWell(
        onTap: () {
          if (!unlocked) {
            _showSnack('🔒 আগে আগের ধাপটি সম্পন্ন করুন!', isError: true);
            return;
          }
          setState(() {
            _guidedStep = stepNum;
            _currentWordIndex = 0;
          });
          _prepareCurrentStepState();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF4F46E5)
                : (unlocked ? Colors.indigo.shade50 : Colors.grey.shade200),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            unlocked ? title : '🔒 $title',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: active ? Colors.white : (unlocked ? Colors.indigo : Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActivePracticeBody(VocabWord currentWord) {
    if (_currentMode == 'guided') {
      if (_guidedStep == 1) return _buildStep1LearnView(currentWord);
      if (_guidedStep == 2) return _buildStep2MatchView();
      if (_guidedStep == 3) return _buildMcqView(currentWord);
      return _buildSpellingView(currentWord);
    } else if (_currentMode == 'flashcard') {
      return _build3DFlashcardView(currentWord);
    } else if (_currentMode == 'mcq') {
      return _buildMcqView(currentWord);
    } else {
      return _buildSpellingView(currentWord);
    }
  }

  // ===========================================================================
  // REAL 3D FLIP FLASHCARD VIEW (WEBSITE-IDENTICAL FRONT & BACK!)
  // ===========================================================================
  Widget _build3DFlashcardView(VocabWord currentWord) {
    final v = _getWordVisualAndExample(currentWord);
    final syllables = _formatSyllables(currentWord.eng);

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _flashcardFlipped = !_flashcardFlipped);
        if (_flashcardFlipped) {
          _triggerSequentialGlowAnimation();
        }
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: _flashcardFlipped ? pi : 0),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutBack,
        builder: (context, angle, _) {
          final isBack = angle >= (pi / 2);
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            child: isBack
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(pi),
                    child: _buildFlashcardBack(currentWord, v),
                  )
                : _buildFlashcardFront(currentWord, syllables),
          );
        },
      ),
    );
  }

  Widget _buildFlashcardFront(VocabWord currentWord, String syllables) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12)],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('🧩 $syllables',
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontWeight: FontWeight.w900,
                        fontSize: 12)),
              ),
              const Text('🃏 3D Flashcard',
                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          Column(
            children: [
              Text(
                currentWord.eng,
                style: const TextStyle(
                    color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => _speak(currentWord.eng, rate: 0.48),
                    icon: const Icon(Icons.volume_up, size: 18),
                    label: const Text('উচ্চারণ শুনুন',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                    ),
                    onPressed: () => _speak(currentWord.eng, rate: 0.28),
                    icon: const Text('🐢'),
                    label: const Text('ধীরে শুনুন',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              '👆 বাংলা অর্থ, চলমান দৃশ্য ও উদাহরণ দেখতে কার্ডে ট্যাপ করুন (Tap to Flip)',
              style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlashcardBack(VocabWord currentWord, Map<String, String> v) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF4F46E5), width: 2),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
      ),
      child: ListView(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(currentWord.eng,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      color: Color(0xFF4F46E5))),
              const Text('👆 আবার ইংরেজি দেখতে ট্যাপ করুন',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.teal.shade300),
            ),
            child: Text(
              currentWord.bng,
              style: TextStyle(
                  color: Colors.teal.shade900,
                  fontSize: 22,
                  fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          _buildAnimatedSceneWidget(currentWord, v),
          const SizedBox(height: 8),
          _buildHighlightedExampleBox(v),
          const SizedBox(height: 8),
          _buildSequential3StepRow(v),
        ],
      ),
    );
  }

  // ===========================================================================
  // WEBSITE-IDENTICAL ANIMATED SCENE + SEQUENTIAL 3-STEP GLOW + STEP 1 VIEW
  // ===========================================================================
  Widget _buildAnimatedSceneWidget(VocabWord currentWord, Map<String, String> v) {
    final sceneType = v['sceneType'] ?? 'study';
    final freqDays = int.tryParse(v['freqDays'] ?? '5') ?? 5;
    final clean = v['clean'] ?? _cleanPrimaryWord(currentWord.eng);
    final shortBng = v['shortBng'] ?? currentWord.bng.split('/')[0];

    return AnimatedBuilder(
      animation: _sceneAnimController,
      builder: (_, __) {
        final t = _sceneAnimController.value;
        final dx = (t - 0.5) * 44;
        final dy = sin(t * pi * 2) * 7;
        final scale = 0.94 + (sin(t * pi) * 0.12);

        if (sceneType == 'scale') {
          return Container(
            height: 92,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.amber.shade50, Colors.orange.shade50, Colors.teal.shade50],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(v['icon1']!, style: const TextStyle(fontSize: 16)),
                    Container(width: 24, height: 18, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(6))),
                    const Text('কম', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                  ],
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text('🔷', style: TextStyle(fontSize: 16)),
                    Container(width: 24, height: 30, decoration: BoxDecoration(color: Colors.indigo.shade300, borderRadius: BorderRadius.circular(6))),
                    const Text('মাঝারি', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                  ],
                ),
                Transform.scale(
                  scale: scale,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.amber.shade600, borderRadius: BorderRadius.circular(10)),
                        child: Text('$clean ($shortBng)', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: 34,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF10B981)]),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(v['icon3']!, style: const TextStyle(fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        if (sceneType == 'timeline') {
          const days = ['শনি', 'রবি', 'সোম', 'মঙ্গল', 'বুধ', 'বৃহঃ', 'শুক্র'];
          final pct = ((freqDays / 7.0) * 100).round();
          return Container(
            height: 92,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.purple.shade50, Colors.indigo.shade50, Colors.teal.shade50]),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.purple.shade200),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(days.length, (idx) {
                    final active = idx < freqDays;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                      decoration: BoxDecoration(
                        color: active ? Colors.teal.shade600 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        days[idx],
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: active ? Colors.white : Colors.grey.shade500,
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: (freqDays / 7.0) * (0.7 + 0.3 * t),
                    minHeight: 7,
                    backgroundColor: Colors.grey.shade200,
                    color: const Color(0xFF4F46E5),
                  ),
                ),
                const SizedBox(height: 4),
                Text('⏱️ $clean = $shortBng ($pct%)',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF3730A3))),
              ],
            ),
          );
        }

        return Container(
          height: 90,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: sceneType == 'water'
                  ? [Colors.cyan.shade50, Colors.blue.shade100]
                  : (sceneType == 'impact'
                      ? [Colors.red.shade50, Colors.amber.shade50]
                      : (sceneType == 'food'
                          ? [Colors.amber.shade50, Colors.green.shade50]
                          : [Colors.indigo.shade50, Colors.teal.shade50])),
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.indigo.shade100),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Transform.scale(
                scale: _activeGlowStep == 1 ? 1.18 : 1.0,
                child: Text(v['icon1']!, style: const TextStyle(fontSize: 26)),
              ),
              Expanded(
                child: Center(
                  child: Transform.translate(
                    offset: sceneType == 'rise'
                        ? Offset(0, -t * 12)
                        : (sceneType == 'fall'
                            ? Offset(0, t * 12)
                            : Offset(dx, sceneType == 'water' ? dy : 0)),
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _activeGlowStep == 2
                                ? const Color(0xFF4F46E5)
                                : Colors.indigo.shade100,
                            width: _activeGlowStep == 2 ? 2.2 : 1.0,
                          ),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 6),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(v['icon2']!, style: const TextStyle(fontSize: 22)),
                            Text(
                              '$clean • $shortBng',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: Color(0xFF4F46E5)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Transform.scale(
                scale: _activeGlowStep == 3 ? 1.18 : 1.0,
                child: Text(v['icon3']!, style: const TextStyle(fontSize: 26)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHighlightedExampleBox(Map<String, String> v) {
    final exEng = v['exEng'] ?? '';
    final target = v['clean'] ?? '';
    final idx = exEng.toLowerCase().indexOf(target.toLowerCase());

    Widget engRichText;
    if (idx >= 0 && target.isNotEmpty) {
      engRichText = RichText(
        text: TextSpan(
          style: const TextStyle(
              color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w700),
          children: [
            TextSpan(text: exEng.substring(0, idx)),
            TextSpan(
              text: exEng.substring(idx, idx + target.length),
              style: const TextStyle(
                backgroundColor: Color(0xFFFEF08A),
                color: Color(0xFF3730A3),
                fontWeight: FontWeight.w900,
              ),
            ),
            TextSpan(text: exEng.substring(idx + target.length)),
          ],
        ),
      );
    } else {
      engRichText = Text(exEng,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14));
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.teal.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('📖 ছোট উদাহরণ বাক্য (Example)',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: Colors.teal.shade900)),
              InkWell(
                onTap: () => _speak(exEng, rate: 0.45),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('🔊 বাক্য শুনুন',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          engRichText,
          const SizedBox(height: 2),
          Text('👉 বাংলা অর্থ: "${v['exBng']}"',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: Colors.teal.shade900)),
        ],
      ),
    );
  }

  Widget _buildSequential3StepRow(Map<String, String> v) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text('🎬 ৩-ধাপে অ্যানিমেশন ব্যাখ্যা',
                    style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        color: Color(0xFF3730A3)),
                    overflow: TextOverflow.ellipsis),
              ),
              InkWell(
                onTap: _triggerSequentialGlowAnimation,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('▶ অ্যানিমেশন',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF4F46E5))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _ExplainStepBox(1, v['icon1']!, v['step1']!, Colors.indigo.shade50),
              const SizedBox(width: 6),
              _ExplainStepBox(2, v['icon2']!, v['step2']!, Colors.teal.shade50),
              const SizedBox(width: 6),
              _ExplainStepBox(3, v['icon3']!, v['step3']!, Colors.amber.shade50),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStep1LearnView(VocabWord currentWord) {
    final v = _getWordVisualAndExample(currentWord);
    final syllables = _formatSyllables(currentWord.eng);
    final allSeen = _seenInStep1.length >= _wordsArray.length;

    return ListView(
      children: [
        // Top mini word pills + AI Tutor button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple.shade600,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => _openAiTutorSheet(currentWord),
              icon: const Icon(Icons.auto_awesome, size: 14),
              label: const Text('✨ AI টিউটর / বাক্য যাচাই', style: TextStyle(fontSize: 11)),
            ),
            if (allSeen && _currentMode == 'guided')
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade600,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: () {
                  setState(() {
                    _guidedStep = 2;
                    _currentWordIndex = 0;
                  });
                  _prepareCurrentStepState();
                },
                child: const Text('🔓 ২য় ধাপ: জোড়া মেলান ➡', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),

        // 1. Animated Visual Scene Card (Category- & Meaning-Specific!)
        _buildAnimatedSceneWidget(currentWord, v),
        const SizedBox(height: 8),

        // 2. Main Word + Syllables + Meaning + Native TTS Audio Buttons
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('🧩 $syllables',
                        style: const TextStyle(
                            color: Colors.amberAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w900)),
                  ),
                  InkWell(
                    onTap: _triggerSequentialGlowAnimation,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text('▶ অ্যানিমেশন',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                currentWord.eng,
                style: const TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  currentWord.bng,
                  style: TextStyle(
                      color: Colors.teal.shade800,
                      fontSize: 17,
                      fontWeight: FontWeight.w900),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => _speak(currentWord.eng, rate: 0.48),
                      icon: const Icon(Icons.volume_up, size: 16),
                      label: const Text('উচ্চারণ শুনুন',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                      ),
                      onPressed: () => _speak(currentWord.eng, rate: 0.28),
                      icon: const Text('🐢'),
                      label: const Text('ধীরে শুনুন',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // 3. Highlighted Example Sentence Card
        _buildHighlightedExampleBox(v),
        const SizedBox(height: 8),

        // 4. Sequential 3-Step Visual Explanation Row
        _buildSequential3StepRow(v),
        const SizedBox(height: 8),

        // 5. Personal Custom Note Box (Just like Website!)
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _noteController,
                decoration: const InputDecoration(
                  hintText: '📝 নিজের মনে রাখার সূত্র বা নোট লিখুন...',
                  border: OutlineInputBorder(),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade600,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                setState(() {
                  _customNotes[currentWord.eng] = _noteController.text.trim();
                });
                _syncProgressToServer();
                _showSnack('📝 আপনার ব্যক্তিগত নোট সেভ হয়েছে!');
              },
              child: const Text('সেভ ✓', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ExplainStepBox(int stepIdx, String icon, String text, Color bg) {
    final isGlowing = _activeGlowStep == stepIdx;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(8),
        transform: Matrix4.identity()..scale(isGlowing ? 1.04 : 1.0),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isGlowing ? const Color(0xFF4F46E5) : Colors.transparent,
            width: isGlowing ? 2.2 : 1.0,
          ),
          boxShadow: isGlowing
              ? const [BoxShadow(color: Colors.black12, blurRadius: 6)]
              : null,
        ),
        child: Column(
          children: [
            Text(icon, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 2),
            Text(
              text,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep2MatchView() {
    return Column(
      children: [
        const Text('🧩 বাম পাশের ইংরেজি শব্দের সাথে ডান পাশের বাংলা অর্থ মেলান!',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  itemCount: _matchEngList.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final w = _matchEngList[i];
                    final done = _matchedWords.contains(w.eng);
                    final selected = _selectedMatchEng == w.eng;
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: done
                            ? Colors.teal.shade100
                            : (selected ? const Color(0xFF4F46E5) : Colors.white),
                        foregroundColor: selected ? Colors.white : Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: done
                          ? null
                          : () {
                              setState(() => _selectedMatchEng = w.eng);
                              _speak(w.eng, rate: 0.48);
                              _checkMatchSelection();
                            },
                      child: Text(w.eng,
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: _matchBngList.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final w = _matchBngList[i];
                    final done = _matchedWords.contains(w.eng);
                    final selected = _selectedMatchBng == w.eng;
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: done
                            ? Colors.teal.shade100
                            : (selected ? Colors.teal.shade700 : Colors.white),
                        foregroundColor: selected ? Colors.white : Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: done
                          ? null
                          : () {
                              setState(() => _selectedMatchBng = w.eng);
                              _checkMatchSelection();
                            },
                      child: Text(w.bng,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _checkMatchSelection() {
    if (_selectedMatchEng == null || _selectedMatchBng == null) return;
    if (_selectedMatchEng == _selectedMatchBng) {
      HapticFeedback.lightImpact();
      setState(() {
        _matchedWords.add(_selectedMatchEng!);
        _selectedMatchEng = null;
        _selectedMatchBng = null;
      });
      if (_matchedWords.length >= _matchEngList.length) {
        setState(() {
          _maxUnlockedGuidedStep = max(_maxUnlockedGuidedStep, 3);
          _guidedStep = 3;
          _currentWordIndex = 0;
        });
        _prepareCurrentStepState();
        _showSnack('🎉 সব জোড়া মিলেছে! ৩য় ধাপ (কুইজ পরীক্ষা) আনলক হয়েছে!');
      }
    } else {
      setState(() {
        _selectedMatchEng = null;
        _selectedMatchBng = null;
      });
      _deductHeartAndCheckReset('💔 ভুল জোড়া! ১টি লাইফ কমেছে!');
    }
  }

  Widget _buildMcqView(VocabWord currentWord) {
    final prompt = _mcqEngToBng ? currentWord.eng : currentWord.bng;
    final correct = _mcqEngToBng ? currentWord.bng : currentWord.eng;

    return ListView(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: () => _speak(currentWord.eng, rate: 0.48),
              icon: const Icon(Icons.volume_up, size: 16),
              label: const Text('উচ্চারণ শুনুন'),
            ),
            TextButton.icon(
              onPressed: () {
                setState(() => _mcqEngToBng = !_mcqEngToBng);
                _prepareCurrentStepState();
              },
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: Text(_mcqEngToBng ? 'ইংরেজি ➔ বাংলা' : 'বাংলা ➔ ইংরেজি'),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Text(
                _mcqEngToBng
                    ? 'নিচের ইংরেজি শব্দটির সঠিক বাংলা অর্থ কোনটি?'
                    : 'নিচের বাংলা অর্থটির সঠিক ইংরেজি শব্দ কোনটি?',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 6),
              Text(
                prompt,
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ..._mcqOptions.map((opt) {
          Color bg = Colors.white;
          Color fg = Colors.black87;
          if (_mcqSelected.isNotEmpty) {
            if (opt == correct) {
              bg = Colors.teal.shade600;
              fg = Colors.white;
            } else if (opt == _mcqSelected) {
              bg = Colors.red.shade600;
              fg = Colors.white;
            }
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: bg,
                foregroundColor: fg,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                alignment: Alignment.centerLeft,
              ),
              onPressed: _mcqSelected.isEmpty ? () => _handleMcqAnswer(opt) : null,
              child: Text(opt, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          );
        }),
        if (_mcqFeedback.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _mcqFeedback,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _buildSpellingView(VocabWord currentWord) {
    final clean = _cleanPrimaryWord(currentWord.eng);
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6D28D9), Color(0xFF4F46E5)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Text(
                _audioOnlySpelling
                    ? '🎧 অডিও ডিক্টেশন মোড: শুধু শুনে বানান লিখুন!'
                    : 'বাংলা অর্থ দেখে ও শুনে ইংরেজি বানানটি সাজান',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                _audioOnlySpelling ? '🔊 🎧 কান পেতে শুনুন...' : currentWord.bng,
                style: const TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () => _speak(currentWord.eng, rate: 0.42),
                    icon: const Icon(Icons.volume_up, size: 15),
                    label: const Text('শুনুন', style: TextStyle(fontSize: 11)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () => setState(() => _audioOnlySpelling = !_audioOnlySpelling),
                    child: Text(_audioOnlySpelling ? '👁️ অর্থ দেখুন' : '🎧 শুধু শুনে লেখার মোড',
                        style: const TextStyle(fontSize: 11)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      setState(() {
                        _usedHintOnCurrentWord = true;
                        _spellFeedback =
                            '💡 হিন্ট: ${clean[0]}...${clean[clean.length - 1]} (${clean.length} অক্ষর — পেনাল্টিসহ)';
                      });
                    },
                    child: const Text('💡 হিন্ট', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: List.generate(_tilePool.length, (idx) {
            final used = _usedTileIndices.contains(idx);
            return InkWell(
              onTap: used
                  ? null
                  : () {
                      setState(() {
                        _usedTileIndices.add(idx);
                        _spellController.text += _tilePool[idx];
                      });
                      if (_spellController.text.length == clean.length) {
                        _handleSpellingSubmit();
                      }
                    },
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: used ? Colors.grey.shade200 : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: used ? Colors.grey.shade300 : const Color(0xFF4F46E5)),
                ),
                child: Text(
                  _tilePool[idx],
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: used ? Colors.grey : Colors.black87,
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _spellController,
                onSubmitted: (_) => _handleSpellingSubmit(),
                decoration: InputDecoration(
                  hintText: 'এখানে ইংরেজি বানান লিখুন...',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                    onPressed: () {
                      setState(() {
                        _spellController.clear();
                        _usedTileIndices.clear();
                      });
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              ),
              onPressed: () => _handleSpellingSubmit(),
              child: const Text('চেক ✓', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ],
        ),
        if (_spellFeedback.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _spellFeedback,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String val;
  final Color color;
  const _StatBox(this.label, this.val, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
            Text(val,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w900, color: color)),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _ModeButton(this.title, this.sub, this.onTap);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.indigo.shade100),
        ),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 2),
            Text(sub,
                style: const TextStyle(fontSize: 10, color: Colors.black54),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final String title;
  final String sub;
  final Color color;
  final VoidCallback onTap;
  const _CategoryTile(this.title, this.sub, this.color, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withOpacity(0.35)),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title,
            style: TextStyle(fontWeight: FontWeight.w900, color: color, fontSize: 15)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: color),
      ),
    );
  }
}
