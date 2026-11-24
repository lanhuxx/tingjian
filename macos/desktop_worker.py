"""Run background model downloads and render transcription drafts."""
import json
import os
import signal
import sys
import tempfile
from pathlib import Path

def downloadable_ids():
    models = json.loads(Path(__file__).with_name("models.json").read_text(encoding="utf-8"))
    return {model["id"] for model in models if model["available"]}


def model_exists(path):
    return any((path / name).is_file() for name in ("config.yaml", "configuration.json")) and any(
        file.is_file() and file.suffix.lower() in {".pt", ".pth", ".bin", ".safetensors"}
        and file.stat().st_size > 0
        for file in path.rglob("*")
    )


def download_models(job):
    from modelscope import snapshot_download

    root = Path(job["modelRoot"]).expanduser().resolve()
    allowed = downloadable_ids()
    for model_id in job["ids"]:
        if model_id not in allowed:
            raise ValueError(f"未识别的模型 ID：{model_id}")
        target = root / model_id
        if model_exists(target):
            continue
        if target.exists() or target.is_symlink():
            raise ValueError(f"目标目录已存在且模型不完整，请移走该目录后再下载：{target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f"正在下载 {model_id}", flush=True)
        with tempfile.TemporaryDirectory(prefix=".funasr-download-", dir=target.parent) as temporary:
            staging = Path(temporary) / "model"
            snapshot_download(model_id=model_id, local_dir=str(staging))
            if not model_exists(staging):
                raise RuntimeError(f"下载未返回完整模型：{model_id}")
            if not model_exists(target):
                staging.rename(target)
        print(f"模型下载完成：{model_id}", flush=True)


def transcribe_draft(job, output):
    source = Path(job["input"]).expanduser().resolve()
    if not source.is_file():
        raise ValueError(f"找不到音频文件：{source}")
    required = ["paraformer-zh", "fsmn-vad"]
    if job["punctuation"]:
        required.append("ct-punc")
    if job["speaker"]:
        required.append("cam++")
    paths = {}
    for key in required:
        path = Path(job["models"][key]).expanduser().resolve()
        if not model_exists(path):
            raise ValueError(f"模型文件缺失或不完整：{path}")
        paths[key] = str(path)

    progress_path = output.with_name("progress.json")
    staging = progress_path.with_suffix(".tmp")

    def progress(stage, processed=0, total=0):
        staging.write_text(json.dumps({"stage": stage, "processed": processed, "total": total}),
                           encoding="utf-8")
        staging.replace(progress_path)

    progress("loading")
    os.environ.setdefault(
        "FUNASR_DATA_DIR", str(Path.home() / "Library/Application Support/LocalFunASR")
    )
    print("正在加载推理环境", flush=True)
    import transcribe as engine

    if source.suffix.lower() not in engine.SUPPORTED_FORMATS:
        raise ValueError(f"不支持的文件格式：{source.suffix}")
    model = engine.load_model(job["speaker"], model_paths=paths, punctuation=job["punctuation"])
    hotwords = job["hotwords"]
    if isinstance(hotwords, list):
        if hotwords:
            vocabulary = output.with_name("hotwords.txt").resolve()
            vocabulary.write_text("\n".join(hotwords) + "\n", encoding="utf-8")
            hotwords = str(vocabulary)
        else:
            hotwords = ""
    engine.process_audio(
        model, source, hotwords, output_path=output,
        sense_voice=job.get("senseVoice", False),
        progress=progress,
        export_options={
            "show_speakers": job["speaker"] and job["showSpeakers"],
            "speaker_prefix": job["prefix"] if job["prefix"].strip() else "说话人 ",
            "speaker_names": job["names"],
            "timestamps": job["timestamps"],
            "plain": job["plain"],
        },
    )


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupt)
    specification = Path(sys.argv[1])
    job = json.loads(specification.read_text(encoding="utf-8"))
    if job.get("action") == "download":
        download_models(job)
    else:
        transcribe_draft(job, specification.with_name("draft.txt"))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("任务已取消")
    except Exception as error:
        sys.exit(f"任务失败：{error}")
