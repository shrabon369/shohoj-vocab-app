# Shohoj Vocab — Native Android App (Flutter)
**Developed by Raz Ahamed**  
Live Backend Connected: `https://vocab.codehutbd.com`

## কীভাবে আপনার ফোনের Kali NetHunter থেকে GitHub-এ পুশ করে APK বানাবেন:

১. প্রথমে আপনার cPanel (`vocab.codehutbd.com`)-এ নতুন দেওয়া **`app.py`** ফাইলটি রিপ্লেস করে **RESTART** দিন (যাতে মোবাইল অ্যাপের লগইন টোকেন কাজ করে)।
২. GitHub-এ একটি নতুন ফাঁকা Repository খুলুন (যেমন: `shohoj-vocab-app`)।
৩. আপনার ফোনের **Kali NetHunter** টার্মিনালে এই জিপ ফাইলটি আনজিপ করে নিচের কমান্ডগুলো চালান:

```bash
mkdir shohoj_app && cd shohoj_app
unzip /path/to/shohoj-vocab-flutter-android.zip
bash push_to_github.sh
```
৪. পুশ শেষ হওয়া মাত্রই আপনার GitHub Repository-র **Actions** ট্যাবে যান—দেখবেন **"Build Shohoj Vocab Android APK"** চলছে এবং ৩–৪ মিনিটের মধ্যে **`Shohoj-Vocab-APK`** (এবং **Releases** সেকশনে `Shohoj-Vocab-by-Raz-Ahamed.apk`) ডাউনলোডের জন্য রেডি হয়ে গেছে!
