#!/usr/bin/env python3
"""UserPromptSubmit hook: voice-reply directive injection + server-side STT.

When a voice message is delivered to a voice/auto-mode agent, this hook:
  1. Passes the attachment_file_id to /api/voice/directive so the server
     transcribes the audio (faster-whisper, no Bash/whisper permission needed).
  2. Injects "[Hang átirat]: <text>" into the prompt when a transcript is returned.
  3. Injects the TTS curl directive so the agent knows to reply with voice.

Claude Code delivers stdout from UserPromptSubmit hooks directly into the model
prompt (no JSON wrapper needed -- plain text is injected as-is). This hook
stays completely silent for non-voice messages.

Never raises: any error results in a silent exit(0) so the prompt is never blocked.
"""
import sys
import os
import json
import re
import urllib.request
import urllib.parse


def _project_root():
    # scripts/hooks/ -> project root (two dirs up)
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _web_port():
    port = os.environ.get("WEB_PORT")
    if not port:
        try:
            with open(os.path.join(_project_root(), ".env")) as f:
                for line in f:
                    if line.startswith("WEB_PORT="):
                        port = line.split("=", 1)[1].strip().strip('"\'')
                        break
        except Exception:
            pass
    return port or "3420"


def _token():
    try:
        with open(os.path.join(_project_root(), "store", ".dashboard-token")) as f:
            return f.read().strip()
    except Exception:
        return ""


def _main_agent_id():
    """Read MAIN_AGENT_ID from .env; fall back to 'marveen'."""
    try:
        with open(os.path.join(_project_root(), ".env")) as f:
            for line in f:
                if line.startswith("MAIN_AGENT_ID="):
                    return line.split("=", 1)[1].strip().strip('"\'')
    except Exception:
        pass
    return "marveen"


def _agent_id(cwd):
    if not cwd:
        return None
    parts = os.path.normpath(cwd).split(os.sep)
    if "agents" in parts:
        i = parts.index("agents")
        if i + 1 < len(parts):
            return parts[i + 1]
    # Fallback: if cwd is the project root itself (main agent session),
    # use MAIN_AGENT_ID so voice config and state_dir resolve correctly.
    project_root = os.path.normpath(_project_root())
    if os.path.normpath(cwd) == project_root:
        return _main_agent_id()
    return None


# --- Local fallback -------------------------------------------------------
#
# MEASURED 2026-09-14 on the omsz box: this hook was ALREADY LOADED in the
# running session, so editing settings.json to point at a second, local hook
# changed nothing -- a loaded hook command is not re-read. The old body then
# called a dashboard that does not exist there, got nothing, and exited
# silently. From the outside that is indistinguishable from "no voice message".
#
# The fix is NOT a second hook file. Two copies of one rule is the failure this
# very situation is made of: the machine-specific shim would be overwritten the
# next time the fleet ships this file. ONE file that handles both installations
# is the cure -- dashboard when there is one, local stt.sh when there is not.

STT_LOCAL = os.environ.get(
    "VOICE_STT_PATH", os.path.expanduser("~/.local/share/marveen-voice/stt.sh"))
STT_STATE_DIR = os.environ.get(
    "VOICE_STATE_DIR", os.path.expanduser("~/.claude/channels/telegram"))
DEBUG = os.environ.get("VOICE_STT_DEBUG") == "1"


def _dbg(msg):
    if DEBUG:
        sys.stderr.write("voice-reply-directive: %s\n" % msg)


def _local_transcript(file_id):
    """Transcribe here, with the caller's OWN bot token (stt.sh reads it from the
    state dir). Never raises: a broken STT must not block a prompt."""
    import subprocess
    try:
        r = subprocess.run([STT_LOCAL, file_id, STT_STATE_DIR],
                           capture_output=True, text=True, timeout=75)
    except Exception as e:
        _dbg("local stt.sh could not run: %s" % e)
        return None
    if r.returncode != 0:
        _dbg("local stt.sh exit=%s stderr=%s" % (r.returncode, (r.stderr or "").strip()[:300]))
        return None
    out = (r.stdout or "").strip()
    if not out:
        _dbg("local stt.sh returned an empty transcript")
    return out or None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    prompt = payload.get("prompt") or ""

    # Gate: only fire for channel-inbound messages (has chat_id).
    # Inter-agent prompts and non-channel input have no chat_id -- skip those.
    # (voice-mode agents must reply with audio even to plain text input, so we
    # cannot gate on attachment_kind="voice" here.)
    m = re.search(r'\bchat_id="(\d+)"', prompt)
    if not m:
        sys.exit(0)
    chat_id = m.group(1)

    # Extract attachment_file_id AND attachment_kind. The kind matters: the
    # Telegram plugin sets attachment_file_id for every attachment type, so the
    # id alone does not mean "voice message". Without the kind the endpoint
    # cannot tell a PDF from a voice note, and an agent in `auto` mode answered
    # a document with a synthesized voice message (2026-07-29).
    m_file = re.search(r'\battachment_file_id="([^"]+)"', prompt)
    file_id = m_file.group(1) if m_file else None
    m_kind = re.search(r'\battachment_kind="([a-z_]+)"', prompt)
    kind = m_kind.group(1) if m_kind else None

    agent_id = _agent_id(payload.get("cwd"))
    if not agent_id:
        sys.exit(0)

    token = _token()
    if not token:
        sys.exit(0)

    port = _web_port()
    url = "http://localhost:%s/api/voice/directive?agent=%s&chat=%s" % (port, agent_id, chat_id)
    if file_id:
        url += "&file=" + urllib.parse.quote(file_id, safe="")
        if kind:
            url += "&kind=" + urllib.parse.quote(kind, safe="")

    data = {}
    try:
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Bearer " + token)
        with urllib.request.urlopen(req, timeout=55) as r:
            data = json.load(r)
    except Exception as e:
        # No dashboard here. That is a legitimate installation, not a failure:
        # an agent on somebody else's network runs the channel and the voice
        # tools locally and talks to the fleet only over HTTPS.
        _dbg("dashboard unavailable (%s) -- falling back to the local STT" % e)

    transcript = data.get("transcript")
    if not transcript:
        # Say WHY there is no fallback, not just that there was none: a debug mode
        # that announces "falling back" and then silently does nothing is the same
        # unreadable silence it was meant to cure.
        if not file_id or kind not in ("voice", "audio"):
            _dbg("no local fallback: not a voice message (kind=%s)" % kind)
        elif not os.access(STT_LOCAL, os.X_OK):
            _dbg("no local fallback: no executable stt.sh at %s" % STT_LOCAL)
        else:
            transcript = _local_transcript(file_id)
    if transcript:
        sys.stdout.write("\n[Hang átirat]: " + transcript + "\n")
        sys.stdout.flush()

    directive = data.get("directive")
    if directive:
        sys.stdout.write(directive)
        sys.stdout.flush()

    sys.exit(0)


if __name__ == "__main__":
    main()
