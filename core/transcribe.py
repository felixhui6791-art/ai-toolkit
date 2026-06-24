#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地语音转文字：用 SenseVoice Small（阿里开源，中文强）+ sherpa-onnx 运行。
依赖很轻，模型也小。需先安装（见 setup/install_deps.sh），用项目自带 .venv 运行。

用法：
  .venv/bin/python core/transcribe.py recordings/clip.wav
结果（纯文本）打印到 stdout。
"""
import sys, os, json

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
CONFIG = os.path.join(PROJ, "config.json")
MODEL_DIR = os.path.join(PROJ, "models", "sensevoice")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法: transcribe.py <音频文件>\n")
        sys.exit(2)
    wav = sys.argv[1]
    with open(CONFIG, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    lang = cfg.get("speech_language", "auto")

    model = os.path.join(MODEL_DIR, "model.int8.onnx")
    tokens = os.path.join(MODEL_DIR, "tokens.txt")
    if not os.path.exists(model):
        sys.stderr.write("语音模型未安装，请先运行 setup/install_deps.sh\n")
        sys.exit(3)

    import wave
    import numpy as np
    import sherpa_onnx
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model,
        tokens=tokens,
        num_threads=2,
        use_itn=True,        # 自动加标点和数字规整
        language=lang,       # zh / en / ja / ko / yue / auto
    )
    # 读取 wav（录音/转码统一为 16k 单声道 16bit PCM）
    with wave.open(wav, "rb") as w:
        sample_rate = w.getframerate()
        n_channels = w.getnchannels()
        raw = w.readframes(w.getnframes())
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if n_channels > 1:
        samples = samples.reshape(-1, n_channels).mean(axis=1)
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples)
    recognizer.decode_stream(stream)
    sys.stdout.write(stream.result.text.strip())


if __name__ == "__main__":
    main()
