# Autonion Agent (Desktop Agent)

## Overview
The **Autonion Agent** is a Flutter-based desktop application that serves as the critical communication hub between your desktop environment and the Android **Automation Companion** app. It handles local connectivity, service discovery, clipboard synchronization, and relays automation commands to either browser extensions or native system automation processes via a Python backend.

## Purpose
The primary purpose of the Autonion Agent is to provide a seamless, unified connection layer on your desktop that:
1. **Advertises its presence** securely over the Local Area Network (LAN) using mDNS (`_myautomation._tcp`), allowing the Android app to automatically discover and pair with your computer without manual IP configuration.
2. **Hosts a local WebSocket Server** (`ws://<IP>:8080/automation`) to facilitate real-time, bi-directional communication between the Android app, the Chrome browser extension, and the desktop Python backend.
3. **Synchronizes the clipboard** across your devices, enabling seamless sharing of text and images directly between Android and your Desktop.
4. **Manages Python-based System Automation** by bridging the Flutter UI to a dedicated Python backend, enabling complex desktop automation actions that originate from the Omni-Chatbot on Android.

## How it works with Automation Companion
1. **Discovery:** When you launch the Autonion Agent on your desktop, it uses mDNS to broadcast its availability on the local network. The Automation Companion (Android) automatically detects this signal and establishes a connection over Wi-Fi.
2. **Web Automation:** When the Android app's Omni-Chatbot generates agentic actions to perform on the web, these commands are sent via WebSocket to the Autonion Agent, which then forwards them to the connected Autonion Chrome Extension to execute DOM interactions securely.
3. **Desktop Automation:** For native desktop tasks, the Android app sends commands to the Agent, which forwards them to its embedded Python backend to interact directly with desktop software or the operating system.

## Key Features
- **Cross-Platform Compatibility:** Built with Flutter, supporting Windows, macOS, and Linux out of the box.
- **Zero-Config Discovery:** Uses mDNS for automatic LAN discovery and pairing.
- **WebSocket Bridge:** A robust, low-latency bridge connecting mobile clients, browser extensions, and Python runtimes.
- **Clipboard Sync:** Bi-directional clipboard synchronization for text and images.
- **Background Execution:** Designed to run quietly in the background, supporting minimizing to the system tray and auto-launching at system startup.
- **Auto-Initialization:** Automatically initializes the Python automation bridge upon startup for a friction-free experience.

## Development Setup

### Prerequisites
- Flutter SDK (`>= 3.9.2`)
- Windows/macOS/Linux build tools (depending on your host OS)
- Python (for the desktop automation backend)

### Running Locally

```bash
# Fetch Flutter dependencies
flutter pub get

# Run the app locally (e.g., on Windows)
flutter run -d windows
```
