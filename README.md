# Dot Wake

A local, menu-bar-only macOS keyword listener for your configured ChatGPT dot.

| Phrase | Action |
|---|---|
| Hey <name> | Start or unmute |
| Mute <name> | Mute |
| Bye <name> | End |

Set the dot name and microphone in the menu-bar panel. Listening starts off; click Start Listening explicitly. Stop Listening releases capture without ending the ChatGPT call. Live audio/features and the bounded activity log stay in memory; no live recordings, uploads or full transcription. ChatGPT calls have their own audio/network behavior.

## Install

Release v0.4.10/build12 is for Apple Silicon, macOS13+. Move Dot Wake.app to Applications. This distribution is ad-hoc signed and not notarized; macOS may block launch. No Developer ID membership is required by the project. Allow this app in System Settings → Privacy & Security → Accessibility, and allow microphone access when you explicitly start listening. Enter your actual dot name. Do not run multiple listeners.

Existing ChatGPT windows use verified semantic background navigation/actions. Missing-window recovery can foreground ChatGPT; quit-app Mute/Bye do not launch/create a call. Unknown or ambiguous identity fails closed. UI-language/app-version changes can break Accessibility matching. Bye/By homophones can trigger the same end command; synthetic tests do not establish human/noise false-trigger rates.

## Build

Install Xcode/Swift, then:

```sh
./scripts/setup-runtime.sh
./scripts/build-app.sh
swift test --disable-sandbox
```

Output: dist/Dot Wake.app. Native sherpa-onnx1.13.8 and ONNX Runtime1.28.2 static artifacts are fetched from official release URLs and verified with pinned SHA256 checksums. The keyword-only Swift wrapper preserves their C ABI. Models are unchanged FP32 English GigaSpeech3.3M streaming Zipformer assets; no quantization. Model files and tokenizer assets are bundled locally, and Python is not needed at runtime or for this build script.

The release binary excludes fixture/call-debug commands. DOT_WAKE_DIAGNOSTICS=1 enables developer diagnostics in a separate build; normal builds never start capture automatically. Current source has29 passing core tests plus offline recognition/lifecycle/resource checks from release preparation. Actual clean-machine install, refreshed app permissions and live menu/call checks remain user-dependent.

## Attribution

Third-party licenses/notices are in licenses/ and included in the app. Model provenance: https://www.modelscope.cn/pkufool/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (model README identifies Apache2.0). Native provenance/checksums are recorded in Vendor/PROVENANCE.md. An overall license for the application's original source has not been selected; third-party components retain their respective licenses.
