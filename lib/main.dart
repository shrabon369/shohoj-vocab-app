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
    with SingleTickerProviderStateMixin {
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
  int _batchSize = 5;

  // Auth & Cloud State
  String? _authToken;
  String? _username;
  bool _isMasterAdmin = false;
  String _announcement = '';
  bool _aiEnabled = true;
  List<dynamic> _leaderboard = [];

  // User Progress State
  List<String> _masteredWords = [];
  List<Map<String, String>> _hardWords = [];
  Map<String, bool> _completedSets = {};
  Map<String, bool> _passedRevisions = {};
  Map<String, String> _customNotes = {};
  int _streakDays = 1;
  String _lastStudyDate = '';

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

  // Hard Discipline Mode State: 3 Hearts, 15s Timer, Hint Penalty, Audio Dictation
  int _sessionHearts = 3;
  int _questionTimeLeft = 15;
  Timer? _questionTimer;
  bool _usedHintOnCurrentWord = false;
  bool _audioOnlySpelling = false;
  bool _flashcardFlipped = false;

  // Step 2 Match State
  List<VocabWord> _matchEngList = [];
  List<VocabWord> _matchBngList = [];
  String? _selectedMatchEng;
  String? _selectedMatchBng;
  Set<String> _matchedWords = {};

  // Step 3 MCQ State
  List<String> _mcqOptions = [];
  String _mcqSelected = '';
  String _mcqFeedback = '';
  bool _mcqEngToBng = true;

  // Step 4 Spelling State
  final TextEditingController _spellController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  List<String> _tilePool = [];
  List<int> _usedTileIndices = [];
  String _spellFeedback = '';

  late AnimationController _sceneAnimController;

  @override
  void initState() {
    super.initState();
    _sceneAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _initApp();
  }

  @override
  void dispose() {
    _questionTimer?.cancel();
    _sceneAnimController.dispose();
    _spellController.dispose();
    _noteController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initApp() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    _prefs = await SharedPreferences.getInstance();

    // Load bundled 2,992 words JSON
    final rawJson = await rootBundle.loadString('assets/vocab_db.json');
    final Map<String, dynamic> decoded = jsonDecode(rawJson);
    final Map<String, List<VocabWord>> parsed = {};
    decoded.forEach((key, list) {
      if (list is List) {
        parsed[key] = list.map((item) => VocabWord.fromJson(item, key)).toList();
      }
    });

    // Load local saved state
    _authToken = _prefs?.getString('authToken');
    _username = _prefs?.getString('username');
    _isMasterAdmin = _prefs?.getBool('isMasterAdmin') ?? false;
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
  }

  Future<void> _saveLocalProgress() async {
    if (_prefs == null) return;
    await _prefs!.setStringList('masteredWords', _masteredWords);
    await _prefs!.setString('hardWords', jsonEncode(_hardWords));
    await _prefs!.setString('completedSets', jsonEncode(_completedSets));
    await _prefs!.setString('passedRevisions', jsonEncode(_passedRevisions));
    await _prefs!.setString('customNotes', jsonEncode(_customNotes));
    await _prefs!.setInt('streakDays', _streakDays);
    await _prefs!.setString('lastStudyDate', _lastStudyDate);
  }

  Map<String, dynamic> _exportProgressPayload() {
    return {
      'masteredWords': _masteredWords,
      'hardWords': _hardWords,
      'completedSets': _completedSets,
      'passedRevisions': _passedRevisions,
      'customNotes': _customNotes,
      'streakDays': _streakDays,
      'lastStudyDate': _lastStudyDate,
      'currentLevelLabel':
          '${_currentCategory.toUpperCase()} — সেট ${_currentSetIndex + 1} (ধাপ $_guidedStep)',
    };
  }

  void _importProgressPayload(Map<String, dynamic>? prog) {
    if (prog == null) return;
    setState(() {
      if (prog['masteredWords'] is List) {
        _masteredWords = (prog['masteredWords'] as List).map((e) => e.toString()).toList();
      }
      if (prog['hardWords'] is List) {
        _hardWords = (prog['hardWords'] as List)
            .map((e) => {
                  'eng': (e['eng'] ?? '').toString(),
                  'bng': (e['bng'] ?? '').toString(),
                })
            .toList();
      }
      if (prog['completedSets'] is Map) {
        _completedSets =
            (prog['completedSets'] as Map).map((k, v) => MapEntry(k.toString(), v == true));
      }
      if (prog['passedRevisions'] is Map) {
        _passedRevisions =
            (prog['passedRevisions'] as Map).map((k, v) => MapEntry(k.toString(), v == true));
      }
      if (prog['customNotes'] is Map) {
        _customNotes =
            (prog['customNotes'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      if (prog['streakDays'] != null) {
        _streakDays = int.tryParse(prog['streakDays'].toString()) ?? 1;
      }
      if (prog['lastStudyDate'] != null) {
        _lastStudyDate = prog['lastStudyDate'].toString();
      }
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
  // WORD HELPERS, VISUALS & EXAMPLES
  // ===========================================================================
  String _cleanPrimaryWord(String raw) {
    var c = raw.replaceAll(RegExp(r'\(.*?\)'), '').trim();
    if (c.contains('/')) c = c.split('/')[0].trim();
    return c.isEmpty ? raw.trim() : c;
  }

  Map<String, String> _getWordVisualAndExample(VocabWord w) {
    final clean = _cleanPrimaryWord(w.eng);
    final low = clean.toLowerCase();
    final shortBng = w.bng.split('/')[0].replaceAll(RegExp(r'\(.*?\)'), '').trim();
    final cat = w.sourceKey.toLowerCase();
    final combined = '$low ${w.bng}';

    String icon1 = '✨', icon2 = '🎯', icon3 = '🌟';
    String exEng = 'Proper $low is important in life.';
    String exBng = 'জীবনে সঠিক $shortBng খুবই গুরুত্বপূর্ণ।';
    String step1 = '১. মূল বিষয় 🏷️';
    String step2 = '২. অর্থ: $clean ($shortBng) ⚡';
    String step3 = '৩. বাস্তব প্রয়োগ 🎯';

    if (RegExp(r'go|walk|run|move|come|reach|leave|travel|return|arrive|যাত্রা|যাওয়া|আসা|হাঁটা|দৌড়').hasMatch(combined)) {
      icon1 = '🏠'; icon2 = '🏃‍♂️'; icon3 = '🏁';
      exEng = 'We $low there every morning.';
      exBng = 'আমরা প্রতিদিন সকালে সেখানে যাই/চলি।';
      step1 = '১. যাত্রা শুরু 🏠'; step2 = '২. চলমান: $clean ($shortBng)'; step3 = '৩. গন্তব্যে পৌঁছানো 🏁';
    } else if (RegExp(r'swim|water|sea|river|float|wash|সাঁতার|পানি|নদী|ধোয়া').hasMatch(combined)) {
      icon1 = '🌊'; icon2 = '🏊‍♂️'; icon3 = '🏝️';
      exEng = 'He likes to $low in the river.';
      exBng = 'সে নদীতে $shortBng পছন্দ করে।';
    } else if (RegExp(r'give|take|send|get|buy|sell|pay|bring|দেওয়া|নেওয়া|পাওয়া|কেনা|বিক্রি').hasMatch(combined)) {
      icon1 = '🧑'; icon2 = '🎁'; icon3 = '👩';
      exEng = 'Please $low this carefully.';
      exBng = 'অনুগ্রহ করে এটি যত্নসহকারে $shortBng।';
    } else if (RegExp(r'write|read|draw|study|learn|know|think|লেখা|পড়া|জানা|চিন্তা|শিক্ষা').hasMatch(combined)) {
      icon1 = '📖'; icon2 = '✍️'; icon3 = '💡';
      exEng = 'Always try to $low new things.';
      exBng = 'সবসময় নতুন কিছু $shortBng চেষ্টা করো।';
    } else if (cat == 'adjective') {
      icon1 = '🔹 কম'; icon2 = '🌟 $shortBng'; icon3 = '🏆 সেরা গুণ';
      exEng = 'This is a very $low example for us.';
      exBng = 'এটি আমাদের জন্য খুবই $shortBng একটি উদাহরণ।';
    } else if (cat == 'adverb') {
      icon1 = '📅 প্রতিদিন'; icon2 = '⏱️ $shortBng'; icon3 = '✅ অভ্যাস';
      exEng = 'He does his work $low.';
      exBng = 'সে $shortBng তার কাজ করে।';
    }

    return {
      'icon1': icon1,
      'icon2': icon2,
      'icon3': icon3,
      'exEng': exEng,
      'exBng': exBng,
      'step1': step1,
      'step2': step2,
      'step3': step3,
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

  void _openSetMapForKeys(List<String> keys, String title) {
    final full = <VocabWord>[];
    for (final k in keys) {
      if (_vocabDb[k] != null) full.addAll(_vocabDb[k]!);
    }
    setState(() {
      _activeKeys = keys;
      _activeTitle = title;
      _categoryFullWords = full;
      _screen = 'set_map';
    });
  }

  void _startSet(int setIdx) {
    if (_hardWords.length >= 10 && _completedSets[_setCompletionKey(setIdx)] != true) {
      _showSnack('🚨 মিস্টেক জেল! ১০টি ভুল শব্দ জমে গেছে! নতুন সেটের আগে ভুল শব্দগুলো ক্লিয়ার করুন!', isError: true);
      _startHardWordsPractice();
      return;
    }
    if (!_isSetUnlocked(setIdx)) {
      _showSnack('🔒 এই সেটটি লক করা! আগে আগের সেট ও বাধ্যতামূলক রিভিশন শেষ করুন!', isError: true);
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
      _sessionHearts = 3;
      _screen = 'practice';
    });
    _prepareCurrentStepState();
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
      _sessionHearts = 3;
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
      _sessionHearts = 3;
      _screen = 'practice';
    });
    _prepareCurrentStepState();
  }

  void _startQuestionTimer(VoidCallback onTimeout) {
    _questionTimer?.cancel();
    setState(() => _questionTimeLeft = 15);
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
    setState(() => _sessionHearts = max(0, _sessionHearts - 1));
    if (_sessionHearts <= 0) {
      _questionTimer?.cancel();
      setState(() {
        _sessionHearts = 3;
        _guidedStep = 1;
        _maxUnlockedGuidedStep = 1;
        _currentWordIndex = 0;
        _seenInStep1 = {0};
      });
      _prepareCurrentStepState();
      _showSnack('💔 ৩টি লাইফ শেষ! সেটটি আবার ১ম ধাপ (দেখা ও শোনা) থেকে শুরু হলো!', isError: true);
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('SV',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
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
                  Chip(label: Text('🔥 ভুল জেল: ${_hardWords.length}/10')),
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
          initialChildSize: 0.85,
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
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Text('SV',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 14)),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('🌟 Shohoj Vocab — Developed by Raz Ahamed',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
              ),
              const SizedBox(height: 12),
              const Text(
                'চলমান ছবি, উদাহরণ ও AI টিউটরের সাহায্যে ২,৯৯২টি ইংরেজি শব্দ চিরতরে মনে রাখুন!',
                style: TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text(
                '৫টি করে শব্দের ছোট সেট • ৩টি লাইফ (❤️❤️❤️) • ১৫ সেকেন্ড টাইমার • প্রতি ৩ সেট পর বাধ্যতামূলক রিভিশন পরীক্ষা!',
                style: TextStyle(color: Colors.white70, fontSize: 13),
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
        const SizedBox(height: 14),
        const Text('🚀 আমাদের বিশেষ সুবিধাসমূহ:',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.55,
          children: const [
            _FeatureCard('🎬 চলমান অ্যানিমেশন', 'প্রতিটি শব্দের অর্থ অনুযায়ী জীবন্ত দৃশ্য ও ৩-ধাপের ব্যাখ্যা।'),
            _FeatureCard('❤️❤️❤️ ৩টি লাইফ ও টাইমার', '৩টি ভুল করলেই সেট রিসেট এবং ১৫ সেকেন্ডের কুইজ টাইমার।'),
            _FeatureCard('🚨 বাধ্যতামূলক রিভিশন', 'প্রতি ৩টি সেট পরপর রিভিশন পাস করলেই পরের সেট আনলক।'),
            _FeatureCard('☁️ ওয়েব ও অ্যাপ সিঙ্ক', 'vocab.codehutbd.com এবং অ্যাপে একই অ্যাকাউন্টে পড়া সেভ থাকে।'),
          ],
        ),
      ],
    );
  }

  Widget _buildMainMenuScreen() {
    return ListView(
      children: [
        // Stats Row
        Row(
          children: [
            _StatBox('মোট শব্দ', '২,৯৯২', Colors.indigo),
            const SizedBox(width: 6),
            _StatBox('মুখস্থ', '${_masteredWords.length}', Colors.teal),
            const SizedBox(width: 6),
            _StatBox('ভুল জেল', '${_hardWords.length}/10', Colors.redAccent),
            const SizedBox(width: 6),
            _StatBox('স্ট্রিক 🔥', '$_streakDays দিন', Colors.amber.shade800),
          ],
        ),
        const SizedBox(height: 12),
        // Guided 4-Step Hero Card
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
              const Text('চলমান অ্যানিমেশন • উদাহরণ • ৩টি লাইফ ❤️ • ১৫ সেকেন্ড টাইমার ⏱️',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
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
              child: _ModeButton('🃏 Flashcard', 'কার্ড ও অ্যানিমেশন', () {
                setState(() {
                  _currentMode = 'flashcard';
                  _screen = 'category';
                });
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ModeButton('✅ MCQ Quiz', '১৫ সেকেন্ড কুইজ', () {
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
          label: Text('🔥 Practice Hard/Mistake Words (${_hardWords.length}/10)',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('$_activeTitle ($_batchSizeটি করে সেট)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  overflow: TextOverflow.ellipsis),
            ),
            TextButton(
              onPressed: () => setState(() => _screen = 'category'),
              child: const Text('← ক্যাটাগরি'),
            ),
          ],
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
  // PRACTICE SCREEN (ZERO-SCROLL ANDROID OPTIMIZED LAYOUT)
  // ===========================================================================
  Widget _buildPracticeScreen() {
    if (_wordsArray.isEmpty) return const SizedBox();
    final currentWord = _wordsArray[_currentWordIndex];
    final heartsStr =
        '❤️' * _sessionHearts + '🖤' * max(0, 3 - _sessionHearts);

    final showTimer = (_currentMode == 'guided' && (_guidedStep == 3 || _guidedStep == 4)) ||
        _currentMode == 'mcq' ||
        _currentMode == 'spelling';

    return Column(
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
      return _buildStep1LearnView(currentWord);
    } else if (_currentMode == 'mcq') {
      return _buildMcqView(currentWord);
    } else {
      return _buildSpellingView(currentWord);
    }
  }

  Widget _buildStep1LearnView(VocabWord currentWord) {
    final v = _getWordVisualAndExample(currentWord);
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

        // 1. Animated Visual Scene Card
        AnimatedBuilder(
          animation: _sceneAnimController,
          builder: (_, __) {
            final offset = sin(_sceneAnimController.value * pi * 2) * 18;
            return Container(
              height: 82,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.indigo.shade50, Colors.teal.shade50],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.indigo.shade100),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(v['icon1']!, style: const TextStyle(fontSize: 24)),
                  Transform.translate(
                    offset: Offset(offset, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [
                          BoxShadow(color: Colors.black12, blurRadius: 6),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(v['icon2']!, style: const TextStyle(fontSize: 22)),
                          Text(
                            '${_cleanPrimaryWord(currentWord.eng)} • ${currentWord.bng.split('/')[0]}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                                color: Color(0xFF4F46E5)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(v['icon3']!, style: const TextStyle(fontSize: 24)),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),

        // 2. Main Word + Meaning + Native TTS Audio Buttons
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

        // 3. Example Sentence Card
        Container(
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
                    onTap: () => _speak(v['exEng']!, rate: 0.45),
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
              Text(v['exEng']!,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
              Text('👉 বাংলা অর্থ: "${v['exBng']}"',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.teal.shade900)),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // 4. 3-Step Visual Explanation Row
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.indigo.shade100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🎬 ৩-ধাপে অ্যানিমেশন ব্যাখ্যা',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: Color(0xFF3730A3))),
              const SizedBox(height: 6),
              Row(
                children: [
                  _ExplainStepBox(v['icon1']!, v['step1']!, Colors.indigo.shade50),
                  const SizedBox(width: 6),
                  _ExplainStepBox(v['icon2']!, v['step2']!, Colors.teal.shade50),
                  const SizedBox(width: 6),
                  _ExplainStepBox(v['icon3']!, v['step3']!, Colors.amber.shade50),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ExplainStepBox(String icon, String text, Color bg) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
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
        // Letter Tile Bank
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

class _FeatureCard extends StatelessWidget {
  final String title;
  final String desc;
  const _FeatureCard(this.title, this.desc);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(fontSize: 10, color: Colors.black54)),
        ],
      ),
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
