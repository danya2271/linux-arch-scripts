Of course. Here is a complete `README.md` file for the `agentio` script. This is formatted in Markdown, which is perfect for platforms like GitHub or for just keeping alongside the script file.

---

# AgentIO: Local LLM Manager for Android Studio

AgentIO is a command-line utility designed to simplify the setup and management of local Large Language Models (LLMs) for use with Android Studio on Linux. It automates the entire process, from compiling `llama.cpp` with GPU acceleration to managing models and running the server.

This script is specifically tailored for Arch Linux, Ubuntu, and Debian-based systems with an NVIDIA GPU.

## Features

-   **Automated Setup**: Installs all necessary dependencies for your distribution (Arch/Ubuntu/Debian).
-   **Bleeding-Edge `llama.cpp`**: Downloads and compiles the absolute latest version of `llama.cpp` from source, ensuring support for new model architectures.
-   **GPU Acceleration**: Automatically detects your NVIDIA CUDA toolkit and builds `llama.cpp` with full GPU offloading support for maximum performance.
-   **Global Command**: Installs itself as a global `agentio` command, accessible from anywhere in your terminal.
-   **Simple Model Management**: Provides easy commands to download, list, start, and stop your LLM server.
-   **VRAM-Aware**: Allows precise control over context size and the number of model layers offloaded to the GPU, preventing "Out of Memory" errors.

## Prerequisites

-   A Linux distribution (tested on Arch Linux, Ubuntu 22.04+).
-   An NVIDIA GPU with the appropriate drivers and CUDA toolkit installed.
-   `sudo` or root access for installing dependencies.
-   An internet connection for downloading source code and models.

## Installation

1.  **Save the Script**: Download or copy the `agentio` script to a file on your system. For example, save it as `~/agentio`.

2.  **Make it Executable**: Open a terminal and run the following command:
    ```bash
    chmod +x ~/agentio
    ```

3.  **Run the Installer**: Execute the script with the `install` command. This will install system dependencies, compile `llama.cpp`, and copy the script to `/usr/local/bin/agentio` for global access.
    ```bash
    ~/agentio install
    ```
    This process will take a few minutes as it compiles `llama.cpp`. After it's done, you can use the `agentio` command from anywhere.

## Usage

### 1. Downloading a Model

First, you need a model in GGUF format. You can find many on Hugging Face.

**Example: Download OmniCoder-9B**
```bash
agentio download https://huggingface.co/bartowski/OmniCoder-9B-GGUF/resolve/main/OmniCoder-9B-Q4_K_M.gguf omnicoder-9b.gguf
```

### 2. Starting the LLM Server

The `start` command takes up to three arguments:
`agentio start <model_name.gguf> [context_size] [gpu_layers]`

-   **`model_name.gguf`**: (Required) The name of the model file you downloaded.
-   **`[context_size]`**: (Optional) The context window size. Defaults to `4096`. Larger values require more VRAM.
-   **`[gpu_layers]`**: (Optional) The number of model layers to offload to the GPU. Defaults to `99` (all layers). **This is the most important setting for VRAM management.**

**Recommended command for RTX 4060:**
```bash
agentio start omnicoder-9b.gguf 32768 20
```

### 3. Checking Server Status

To see if the server is running, use:
```bash
agentio status
```
> **Output:** `Server is RUNNING (PID: 12345)` or `Server is STOPPED.`

### 4. Stopping the Server

To stop the background server process, run:
```bash
agentio stop
```

### 5. Listing Downloaded Models

To see all the models you have downloaded into the `~/.agentio/models` directory:
```bash
agentio list
```

### 6. Updating `llama.cpp`

If a new model architecture is released that `llama.cpp` doesn't support, you can easily pull the latest updates and recompile:
```bash
agentio update
```

## Connecting to Android Studio

Once the server is running (`agentio status` shows RUNNING), you can connect your IDE.

1.  In Android Studio, go to **Settings** -> **Tools** -> **AI** -> **Model Providers**.
2.  Click on the **llama.cpp** provider in the list.
3.  Ensure the **Port** is set to `8080`.
4.  Click the blue **Refresh** button on the right.
5.  The "Available models" dropdown should now populate with the name of your model. Select it.
6.  Click **Apply** or **OK**.

You can now use Android Studio's built-in AI features, powered entirely by your local GPU!

## Troubleshooting

**Q: The server crashes immediately after starting!**

**A:** This is almost always an "Out of Memory" (OOM) error. Your GPU does not have enough free VRAM to hold the entire model *and* the context window.

-   **Solution:** Use the `[gpu_layers]` parameter to offload fewer layers to the GPU. For an RTX 4060, a value of `24` is a great starting point: `agentio start your_model.gguf 4096 24`.

-   **Check Logs:** You can see the exact error message by viewing the log file:
    ```bash
    cat ~/.agentio/server.log
    ```

## License

This script is released under the MIT License.
