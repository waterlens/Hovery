# Auto Translator extension

Auto Translator translates the text under the pointer with an OpenAI-compatible Chat Completions service that you choose. Sentences, paragraphs, and text blocks are translated; a single word is explained like a dictionary entry. Text that is already in your target language is translated into a second language instead.

The installable package is `Extension/AutoTranslator.hoveryextension`. It is a Web-only extension with no build step. Install it with `just install-auto-translator`, or copy the directory into the folder shown by **Extensions… → Open Extensions Folder** and choose **Reload**.

## Setup

Click the gear button next to Auto Translator in **Extensions…**, or the gear button at the top of the results panel, and enter:

| Setting | Description |
| --- | --- |
| Base URL | The service's OpenAI-compatible endpoint, including its version path. Requests go to `<Base URL>/chat/completions`. |
| API Key | Sent as a Bearer token and stored in your Keychain. Leave it empty for local servers that do not need one. |
| Model | The model name the service expects. |

The remaining settings choose the target language, the language used for text that is already in the target language, how much text to translate, whether to show responses while they stream, the timeout, and optional instructions added to the prompt.

Common endpoints:

| Service | Base URL |
| --- | --- |
| OpenAI | `https://api.openai.com/v1` |
| DeepSeek | `https://api.deepseek.com/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` |
| Groq | `https://api.groq.com/openai/v1` |
| Mistral AI | `https://api.mistral.ai/v1` |
| Alibaba Cloud Model Studio | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Moonshot AI | `https://api.moonshot.cn/v1` |
| Zhipu AI | `https://open.bigmodel.cn/api/paas/v4` |
| SiliconFlow | `https://api.siliconflow.cn/v1` |
| Ollama | `http://localhost:11434/v1` |
| LM Studio | `http://localhost:1234/v1` |

Extensions run as isolated web pages, so the service must allow cross-origin requests (CORS). The hosted services above allowed them when this example was written. Local servers usually need them enabled: start Ollama with `OLLAMA_ORIGINS="*"`, or turn on CORS in LM Studio's server settings. Use `https` for anything other than a local server.

## Privacy

Auto Translator sends the text it translates, the prompt, and your API key to the Base URL you enter. Hovery only allows the extension to connect to that URL's origin.

## Structure

- `web/translator.js` builds the prompt and reads Chat Completions responses, including streamed server-sent events. It hides the `<think>` reasoning that some models include in their answers.
- `web/translations.js` remembers recent translations. Hovery presents a sentence again whenever the pointer moves to another word in it, so presentations of the same text share one request.
- `web/main.js` highlights the translated text and shows the result, setup guidance, or an error.

Run the tests with `just test-translator`. They require Node.js 20.3 or later.
