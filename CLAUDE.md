# Project: Custom voice assistant to replace Gemini for Home

## Goal
I use Google/Nest speakers running Gemini for Home. It does most of what I
want (music, weather, alarms, calendar, general questions), but it asks a
follow-up question after almost every answer, which breaks my concentration,
and there's no setting to disable that. I'm building my own voice assistant
with Home Assistant so I can fully control the assistant's behavior — the key
requirement is that it answers briefly and NEVER asks follow-up questions.

Additional requirements:
- **Web answers**: The assistant should be able to look things up on the web
  and answer with live information (weather, news, current events, prices, etc.)
  — not just from its training data.
- **Chinese (Mandarin)**: Eventually I want to speak to it in Chinese and have
  it respond in Chinese. This affects the choice of LLM (Qwen models are
  stronger than llama for Chinese), the STT language setting, and the TTS voice.
- **Free services ONLY**: I want to use free/local services only. Do NOT use
  the Claude API or any other paid API — everything should run locally or use
  a free tier. This rules out the paid-Claude fallback that was previously
  under consideration.

## Build order (MVP first)
I'm starting with the smallest thing that works and adding one piece at a time,
testing each before moving on:
1. **MVP**: Talk to a local model on my laptop by TYPING (no voice yet).
2. Voice mode (wake word, speech-to-text, text-to-speech).
3. Chinese language.
4. Live web search.
5. Music.
6. Move it all to a dedicated always-on device.

Minor upgrade (any time, low priority): make the model say numbers naturally.
TTS currently reads "$3.50" as "three dollars (pause) fifty" and "7:30" as
"seven (pause) 30". Fix is a system-prompt change only (no new parts): tell
llama to spell such things out — "three dollars and fifty cents", "seven
thirty" — so the TTS voice reads them correctly.

Optional extra (any time, low priority): save conversation transcripts to a
file so I can read them back later. By default HA only keeps a conversation in
memory for ~5 min and never saves it to disk; the simple route is an HA
automation that listens for Assist events and appends each Q&A to a text file.

## Stage
I'm in the testing phase. I want to get this working on my laptop and test it
by typing before I buy any hardware or set up voice. This laptop is NOT the
long-term home for it — eventually the "brain" will move to an always-on
device (a Raspberry Pi, mini PC, or Home Assistant Green).

## My hardware (the test machine)
- Lenovo Legion Slim 5 gaming laptop, Windows
- Ryzen 7 7840HS, 16GB RAM, RTX 4060 (8GB VRAM), 1TB SSD

## Architecture I'm building
- Home Assistant OS running in a VirtualBox VM on this laptop, bridged
  networking so it has its own IP. Reached at http://homeassistant.local:8123
- The "brain" (conversation agent) — I'm trying a FREE local model first:
  Ollama running on Windows (host), serving llama3.1:8b (or qwen3:4b),
  with OLLAMA_HOST=0.0.0.0 on port 11434 so the VM can reach it.
- Home Assistant's Assist pipeline ties it together: wake word -> speech to
  text -> conversation agent -> text to speech.

## Still undecided
- Music: I currently use YouTube Music. On this setup it works via Music
  Assistant but is finicky (needs Premium, fragile cookie login that breaks
  periodically). Spotify/Apple Music are smoother. Haven't decided yet.
- Voice hardware: later I'll add a voice satellite (Home Assistant Voice
  Preview Edition, a cheap Echo, or a spare Android phone as the talking
  endpoint). Not now.

## My preferences
- Keep things SIMPLE — explain clearly, don't overwhelm me, I'm not a
  Home Assistant expert.
- Cost-conscious — I want to try the free local model before paying for
  any API.
- Ask before anything that needs admin rights or makes persistent changes.

## What I want your help with
- The command-line parts: scripting the VirtualBox VM creation (VBoxManage:
  create VM, set RAM/CPU, enable EFI, attach the .vdi, bridged network),
  downloading images, installing/configuring Ollama, pulling models, env
  vars, firewall rules, and verifying things work.
- Note: the Home Assistant web UI steps (onboarding, adding integrations,
  choosing the conversation agent, writing the system prompt) I'll do myself
  in the browser — just guide me through those, you can't click them.

## Current status — MVP WORKING (2026-06-23)

**Step 1 of the build order is DONE.** I can type a question to Home Assistant
and get a short answer from the local model, with no follow-up questions.
Tested: "What's the capital of France?" -> "Paris." Behavior is exactly the
goal — brief, no follow-ups.

### Done
- VirtualBox 7.2.10 installed at C:\Program Files\Oracle\VirtualBox\
- HA OS 18.0 VDI downloaded and extracted to C:\DEV\home-robot\haos_ova-18.0.vdi
- Ollama 0.30.9 installed; OLLAMA_HOST=0.0.0.0 (user env var); firewall
  inbound rule open on port 11434
- VM "HomeAssistant" created: 4 GB RAM, 2 CPUs, EFI, SATA, bridged to
  "RZ616 Wi-Fi 6E 160MHz"; VM running, HA reachable at homeassistant.local:8123
- llama3.1:8b fully downloaded (4.9 GB, Q4_K_M) and verified responding
- Ollama integration added in HA, pointed at http://192.168.1.187:11434
- Assist pipeline created with Ollama as conversation agent, STT/TTS = None,
  brief "no follow-up questions" system prompt pasted in. Tested by typing. ✅

### Key facts to remember
- Host LAN IP (VM reaches Ollama here): 192.168.1.187:11434
  NOTE: this is a DHCP address — if it changes, the HA Ollama integration breaks.
  Set a router DHCP reservation before relying on it long-term.
- Conversation model: llama3.1:8b (switched from qwen3:4b earlier)

### Known rough edge (not blocking)
- First answer after a cold start is slow while the model loads into VRAM;
  later answers are faster. Measured 2026-06-23: warm ~1.6s, cold ~8s (the ~6.4s
  reload is the culprit). Fix planned next session = pin model with
  OLLAMA_KEEP_ALIVE=-1. See memory/project-state.md.

### Voice mode (Step 2) — DONE 2026-06-23
- Whisper (STT) + Kokoro af_sky (TTS, native Windows Wyoming server on the host,
  port 10200) wired into the "Robot" Assist pipeline. Voice confirmed excellent.
- Kokoro server: C:\DEV\home-robot\kokoro\ (kokoro_wyoming.py + run_kokoro.ps1).
  Not auto-started — re-run run_kokoro.ps1 after a reboot.

### Pending — finish OFF-SITE backup setup (one-time, in the HA browser)
- The Backup Robot menu now has option 4 to copy backups OFF the laptop (so the
  robot survives total laptop loss), but the one-time HA setup isn't done yet.
  TO DO when I'm back: (1) install the HA "Samba share" add-on (set user/pass,
  Start); (2) optionally create a long-lived token; (3) Backup Robot → 4 to enter
  IP/off-site folder (a OneDrive folder)/creds; (4) press Backup and confirm a
  .tar lands in the folder. Full steps: backup-recovery.html. Until then, only the
  CODE is safe off-machine (GitHub); the HA config still lives only on this laptop.

### Next step — LATENCY TUNING, then Step 3 (Chinese)
- Make it feel real-time: (1) pin the model in VRAM, (2) streaming TTS in the HA
  UI, (3) shorter-answer system prompt. Maybe swap to a 3B model. Details and the
  measured timings are in memory/project-state.md. After that: Chinese, web
  search, music, move to a dedicated always-on device. All free/local.