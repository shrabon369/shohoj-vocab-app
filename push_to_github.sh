#!/bin/bash
echo "===================================================="
echo "  Shohoj Vocab — GitHub Auto-APK Push Script"
echo "  Developed by Raz Ahamed"
echo "===================================================="
read -p "আপনার নতুন GitHub Repo URL দিন (যেমন https://github.com/Raz-Ahamed/shohoj-vocab-app.git): " REPO_URL

git init
git branch -M main
git add -A
git commit -m "Initial commit: Shohoj Vocab Native Flutter Android App + Auto APK Builder"
git remote remove origin 2>/dev/null
git remote add origin "$REPO_URL"
git push -u origin main --force

echo "✅ সফলভাবে GitHub-এ পুশ হয়েছে! এবার আপনার GitHub Repo-এর Actions ট্যাবে গেলেই ৩-৪ মিনিটে APK ডাউনলোড করতে পারবেন!"
