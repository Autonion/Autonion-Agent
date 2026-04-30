# Autonion Agent (Desktop Agent)

## Overview
The **Autonion Agent** is a Flutter-based desktop application that serves as the critical communication hub between your desktop environment and the Android **Automation Companion** app. It handles local connectivity, service discovery, clipboard synchronization, AI-powered automation, and relays commands to either browser extensions or native system automation processes via a Python backend.

## Offline-First, Cloud-Enhanced Architecture
The Autonion Agent supports a **hybrid AI model** that prioritizes local processing while optionally leveraging cloud-based LLMs for enhanced intelligence:

| Mode | Description | Privacy |
|------|-------------|---------|
| **Ollama (Local)** | Runs LLMs entirely on-device via Ollama. Zero data leaves your machine. | 🟢 Full Privacy |
| **Cloud API** | Connects to third-party LLM APIs (OpenAI, Gemini, Groq, DeepSeek, OpenRouter, etc.). | 🟡 Data sent to cloud provider |
| **Web-Based** | Delegates requests to the Autonion Chrome Extension (ChatGPT/Gemini DOM). | 🟡 Data processed by web service |

> ⚠️ **Privacy Notice:** When using Cloud API or Web-Based modes, your automation prompts and context data are sent to external servers. You are responsible for reviewing the privacy policies of your chosen provider. **We are not responsible for any data exposure when using cloud-based AI services.** Use local Ollama mode for maximum privacy.

### Secure API Key Storage
All third-party API keys are stored using **`flutter_secure_storage`**, which provides:
- **Windows:** DPAPI (Data Protection API) encryption
- **macOS:** Keychain
- **Linux:** libsecret

API keys are **never stored in plaintext**. Existing plaintext keys from prior versions are automatically migrated to secure storage on first launch.

## Purpose
The primary purpose of the Autonion Agent is to provide a seamless, unified connection layer on your desktop that:
1. **Advertises its presence** securely over the Local Area Network (LAN) using mDNS (`_myautomation._tcp`), allowing the Android app to automatically discover and pair with your computer without manual IP configuration.
2. **Hosts a local WebSocket Server** (`ws://<IP>:8080/automation`) to facilitate real-time, bi-directional communication between the Android app, the Chrome browser extension, and the desktop Python backend.
3. **Synchronizes the clipboard** across your devices, enabling seamless sharing of text and images directly between Android and your Desktop.
4. **Manages Python-based System Automation** by bridging the Flutter UI to a dedicated Python backend, enabling complex desktop automation actions that originate from the Omni-Chatbot on Android.
5. **Provides configurable AI inference** with three provider modes (Ollama, Cloud API, Web-Based), each with distinct privacy and capability trade-offs.

## How it works with Automation Companion
1. **Discovery:** When you launch the Autonion Agent on your desktop, it uses mDNS to broadcast its availability on the local network. The Automation Companion (Android) automatically detects this signal and establishes a connection over Wi-Fi.
2. **Web Automation:** When the Android app's Omni-Chatbot generates agentic actions to perform on the web, these commands are sent via WebSocket to the Autonion Agent, which then forwards them to the connected Autonion Chrome Extension to execute DOM interactions securely.
3. **Desktop Automation:** For native desktop tasks, the Android app sends commands to the Agent, which forwards them to its embedded Python backend to interact directly with desktop software or the operating system.
4. **AI Model Selection:** The AI provider (Ollama, Cloud API, or Web-Based) is configured directly on the Desktop Agent via **Settings → AI Settings**. The Android Cross-Device screen defers model selection to the Agent.

## Key Features
- **Cross-Platform Compatibility:** Built with Flutter, supporting Windows, macOS, and Linux out of the box.
- **Zero-Config Discovery:** Uses mDNS for automatic LAN discovery and pairing.
- **WebSocket Bridge:** A robust, low-latency bridge connecting mobile clients, browser extensions, and Python runtimes.
- **Hardware Remote Support:** Receives and executes remote presentation and media commands directly from the Android app's hardware remote module.
- **Intelligent Task Routing:** Automatically distinguishes between browser DOM tasks (routed to extension) and native OS automation (executed via Python).
- **Clipboard Sync:** Bi-directional clipboard synchronization for text and images.
- **Background Execution:** Designed to run quietly in the background, supporting minimizing to the system tray and auto-launching at system startup.
- **Auto-Initialization:** Automatically initializes the Python automation bridge upon startup for a friction-free experience.
- **Hybrid AI Engine:** Supports local LLMs (Ollama), cloud LLM APIs, and web-based AI with encrypted credential storage.
- **Secure Credential Storage:** API keys are encrypted via `flutter_secure_storage` (DPAPI on Windows, Keychain on macOS, libsecret on Linux).

## Development Setup

### Prerequisites
- Flutter SDK (`>= 3.9.2`)
- Windows/macOS/Linux build tools (depending on your host OS)
- Python (for the desktop automation backend)
- Ollama (optional, for local LLM inference)

### Running Locally

```bash
# Fetch Flutter dependencies
flutter pub get

# Run the app locally (e.g., on Windows)
flutter run -d windows
```

### AI Provider Configuration
1. Launch the Agent and navigate to **Settings → AI Settings**.
2. Select your preferred provider:
   - **Ollama:** Enter host/port/model. The Agent will auto-launch Ollama if installed.
   - **API Key:** Enter your API key, endpoint URL, and model name. Keys are stored securely.
   - **Web-Based:** No configuration needed — delegates to the Chrome extension.
3. Use **Test Connection** to verify your setup.
