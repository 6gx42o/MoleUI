#!/usr/bin/env python3
"""Replace personal names in fixtures/ with consistent stand-ins.

Fixtures are real `mo` output captured on a real Mac, which makes them good
tests and bad things to publish. Every path component, file name, app name and
hostname that is not a generic macOS folder becomes a stable token derived from
a hash, so the same name maps to the same token across files (an analyze entry's
name still matches the last component of its path). Sizes, counts and layout are
untouched, so the self-test exercises exactly the same parsing.

Usage: scripts/sanitize-fixtures.py [fixtures-dir]
"""
import hashlib, json, os, re, sys

HOME = os.path.expanduser("~")
USER = os.path.basename(HOME)

GENERIC = {
    "Users", "user", "Library", "Caches", "Application Support", "Containers", "Data",
    "Logs", "Preferences", "Saved Application State", "HTTPStorages", "WebKit",
    "Group Containers", "Mail", "Messages", "Safari", "Cookies", "tmp", "T", "var",
    "folders", "private", "Downloads", "Documents", "Desktop", "Pictures", "Movies",
    "Music", "Public", "Applications", "Developer", "Xcode", "DerivedData", "Archives",
    "CoreSimulator", "Devices", "iOS DeviceSupport", "Homebrew", "Cellar", "opt",
    "node_modules", "venv", ".venv", "__pycache__", ".build", "build", "dist", ".cache",
    "pip", "npm", "_cacache", ".npm", "Yarn", "pnpm", "store", ".gradle", ".cargo",
    "registry", "go", "pkg", "mod", "System", "usr", "local", "bin", "lib", "share",
    "Volumes", ".Trash", "Contents", "MacOS", "Resources", "Frameworks", "PlugIns",
    "com.apple.Safari", "Mobile Documents", "iCloud", "Fonts", "Extensions",
    "LaunchAgents", "Python", "site-packages", "Trash",
}

def token(name):
    if name in GENERIC or name == "" or name.startswith("com.apple."):
        return name
    root, ext = os.path.splitext(name)
    if ext and not re.fullmatch(r"\.[A-Za-z0-9]{1,12}", ext):
        root, ext = name, ""
    digest = hashlib.sha1(name.encode()).hexdigest()[:6]
    prefix = "App" if ext == ".app" else "item"
    return f"{prefix}-{digest}{ext}"

def anon_path(path):
    if path.startswith("~/"):
        path = HOME + path[1:]
        tilde = True
    else:
        tilde = False
    parts = path.split("/")
    out = [p if i == 0 else ("user" if p == USER else token(p)) for i, p in enumerate(parts)]
    result = "/".join(out)
    if tilde:
        result = result.replace("/Users/user", "~", 1)
    return result

PATH_RE = re.compile(r"(?:~|/Users/[^/\s\"',]+|/Volumes|/Applications|/Library)(?:/[^\s\"',|:]+(?: [^\s\"',|:/]+)*)*")

def anon_text(text):
    text = text.replace(HOME, "/Users/user")
    text = PATH_RE.sub(lambda m: anon_path(m.group(0)), text)
    # Selector rows: "○ Affinity.dmg      1.01GB | Downloads"
    text = re.sub(r"([○●➤]\s+(?:[○●]\s+)?)(\S(?:.*?\S)?)(\s{2,}[0-9.]+[KMGT]?B\s+\|)",
                  lambda m: m.group(1) + token(m.group(2)) + m.group(3), text)
    # "Vorssaint-3.4.2.dmg → /Volumes/…"
    text = re.sub(r"(\s)([^\s/]+\.(?:dmg|pkg|iso|xip|zip))(\s→)",
                  lambda m: m.group(1) + token(m.group(2)) + m.group(3), text)
    # App names in free text ("Chrome cache · 102MB"), learned from apps.json.
    for word in APP_WORDS:
        text = re.sub(r"(?<![\w.-])" + re.escape(word) + r"(?![\w-])", token(word), text)
    return text.replace(USER, "user")

# Words that appear in app names but are ordinary English or macOS vocabulary;
# replacing them would mangle Mole's own labels ("System caches", "App data").
STOPWORDS = {"the", "for", "and", "app", "apps", "pro", "mac", "macos", "helper", "cache",
             "data", "code", "player", "desktop", "studio", "edition", "game", "system",
             "update", "updater", "launcher", "support", "files", "manager", "tools",
             "home", "status", "content", "shared", "group", "state", "application",
             "with", "lite", "free", "plus", "one", "web", "music", "photos", "mail"}
APP_WORDS = []

def learn_app_words(root):
    path = os.path.join(root, "apps.json")
    if not os.path.exists(path):
        return
    words = set()
    for app in json.load(open(path)):
        for field in ("name", "uninstall_name"):
            if not app.get(field, "").startswith("item-"):
                words.update(w for w in re.split(r"[\s.+()_-]+", app.get(field, ""))
                             if len(w) >= 3 and w.lower() not in STOPWORDS and not w.isdigit())
    # Longest first, so "Chrome" inside "Google Chrome" is not split mid-name.
    APP_WORDS.extend(sorted(words, key=len, reverse=True))

def anon_json(value, key=None):
    if isinstance(value, dict):
        return {k: anon_json(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [anon_json(v, key) for v in value]
    if isinstance(value, str):
        if key in ("name", "uninstall_name", "command") and "/" not in value:
            return value if key == "command" else token(value)
        if key == "bundle_id":
            if value.startswith("com.apple.") or value == "unknown":
                return value
            return "com.example.app-" + hashlib.sha1(value.encode()).hexdigest()[:6]
        if key == "host":
            return "Mac.local"
        return anon_text(value)
    return value

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "fixtures")
    learn_app_words(root)       # before apps.json itself is rewritten
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        raw = open(path, encoding="utf-8", errors="surrogateescape").read()
        if name.endswith(".json"):
            data = json.loads(raw)
            # Process lists stay real: they are system daemons, not personal.
            procs = data.get("top_processes") if isinstance(data, dict) else None
            out = anon_json(data)
            if procs is not None:
                out["top_processes"] = procs
            new = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
        else:
            new = anon_text(raw)
        if new != raw:
            open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
            print("sanitized", name)

if __name__ == "__main__":
    main()
