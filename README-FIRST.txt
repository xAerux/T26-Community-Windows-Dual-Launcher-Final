T26 COMMUNITY WINDOWS DUAL-LAUNCHER PACKAGE

1. Extract the entire ZIP to a normal folder before launching anything.
   Do not run the application from inside the ZIP viewer.

2. Run Launch-T26-Standard.cmd for the promoted standard release, or
   Launch-T26-Developer.cmd for the verified developer release.

3. Each launcher first runs Setup-T26.cmd. It reads the packaged
   runtimeconfig.json files and checks for compatible x64 .NET 9 runtimes:
   Microsoft.NETCore.App, Microsoft.WindowsDesktop.App, and
   Microsoft.AspNetCore.App. An x86 runtime is not accepted as x64.

4. If a runtime is missing, the preflight reports the exact requirement and
   asks before any official winget installation is attempted. Manual Microsoft
   download instructions are shown when winget is unavailable. No runtime is
   installed silently, and the .NET SDK is not required by this package.

5. Optional local AI setup is available with Setup-T26-LocalAI.ps1. It detects
   hardware, reuses compatible installed Ollama models, and recommends
   supported Qwen3 models. Model downloads and the optional local inference
   probe require explicit approval. No model weights are included here.

6. This package has not been physically accepted on a clean Windows machine.
   Fresh-machine startup, Ollama behavior, and live T26 AI behavior remain
   UNVERIFIED.

7. Use a disposable test environment for machine-control features. Never use
   private workspaces, credentials, or personal databases during testing.

8. Report bugs at the project's GitHub issue tracker after publication. Include
   the channel used, visible error text, Windows version, .NET preflight result,
   and safe reproduction steps. Do not attach secrets, private data, or model
   files.

License: Apache License 2.0. See LICENSE and THIRD-PARTY-NOTICES.txt.
