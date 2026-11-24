import os
import time
import argparse
import subprocess
import tempfile
import traceback
from pathlib import Path
from functools import wraps


# ============================================================
# 1. 项目路径配置
# ============================================================

BASE_DIR = Path(os.environ.get("FUNASR_DATA_DIR", Path(__file__).resolve().parent))

MODEL_DIR = BASE_DIR / "model"
AUDIO_DIR = BASE_DIR / "audio"
OUTPUT_DIR = BASE_DIR / "output"
HOTWORDS_FILE = BASE_DIR / "hotwords.txt"

# 自动创建项目目录
for directory in [MODEL_DIR, AUDIO_DIR, OUTPUT_DIR]:
    directory.mkdir(parents=True, exist_ok=True)

# 设置模型缓存路径
os.environ["MODELSCOPE_CACHE"] = str(MODEL_DIR)


# ============================================================
# 2. 导入第三方依赖
# ============================================================

import torch
import numpy as np

from funasr import AutoModel
from modelscope import snapshot_download
from funasr.models.campplus.cluster_backend import ClusterBackend


# ============================================================
# 3. FunASR 说话人聚类兼容性修复
# ============================================================

def patch_cluster_backend():
    """
    修复 FunASR CAM++ 说话人聚类兼容性问题。

    错误信息：
    TypeError: Cannot interpret 'torch.float32' as a data type

    原因：
    FunASR 将 PyTorch Tensor 直接传递给 UMAP，
    导致 NumPy 无法识别 PyTorch 的数据类型。

    解决方法：
    在 ClusterBackend.forward 入口处，
    将 Tensor 统一转换成 NumPy float32 数组。
    """

    # 避免重复应用补丁
    if getattr(ClusterBackend, "_numpy_patch_applied", False):
        return

    original_forward = ClusterBackend.forward

    @wraps(original_forward)
    def patched_forward(self, X, *args, **kwargs):

        if isinstance(X, torch.Tensor):

            X = X.detach().cpu().float().numpy()

        else:

            X = np.asarray(X, dtype=np.float32)

        # 确保数组在内存中连续存储
        X = np.ascontiguousarray(X, dtype=np.float32)

        return original_forward(
            self,
            X,
            *args,
            **kwargs
        )

    ClusterBackend.forward = patched_forward
    ClusterBackend._numpy_patch_applied = True

    print("[兼容性修复] CAM++ 说话人聚类补丁已加载")


# 应用兼容性补丁
patch_cluster_backend()


# ============================================================
# 4. 参数配置
# ============================================================

# 推理设备：cpu / mps
DEVICE = "cpu"

# CPU 推理线程数量
NCPU = 8

# 每批次音频总时长，单位：秒
BATCH_SIZE_S = 60

# 是否开启说话人区分
ENABLE_SPEAKER = True

# VAD 单个语音片段最大时长，单位：毫秒
MAX_SINGLE_SEGMENT_TIME = 30000

# 支持的音频和视频格式
SUPPORTED_FORMATS = {
    ".wav",
    ".mp3",
    ".m4a",
    ".mp4",
    ".aac",
    ".flac",
    ".ogg",
    ".wma",
    ".amr",
    ".mov",
    ".webm",
    ".opus"
}

# ModelScope 模型仓库配置
MODEL_CONFIG = {
    "paraformer-zh": (
        "iic/speech_seaco_paraformer_large_asr_"
        "nat-zh-cn-16k-common-vocab8404-pytorch"
    ),

    "fsmn-vad": (
        "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
    ),

    "ct-punc": (
        "iic/punc_ct-transformer_cn-en-common-vocab471067-large"
    ),

    "cam++": (
        "iic/speech_campplus_sv_zh-cn_16k-common"
    )
}


# ============================================================
# 5. 下载或加载本地模型
# ============================================================

def get_model_path(model_name: str) -> str:
    """
    检查模型是否已经下载。

    如果模型已经存在，则直接加载本地模型。
    否则从 ModelScope 下载到项目 model 目录。
    """

    if model_name not in MODEL_CONFIG:
        raise ValueError(f"未知模型：{model_name}")

    local_path = MODEL_DIR / model_name

    ready_file = local_path / ".download_complete"

    config_exists = (
        (local_path / "config.yaml").exists()
        or
        (local_path / "configuration.json").exists()
    )

    # 检查本地模型权重
    weight_exists = any(
        file.is_file()
        and file.suffix.lower() in {
            ".pt",
            ".pth",
            ".bin",
            ".safetensors"
        }
        for file in local_path.rglob("*")
    )

    # 已下载的模型直接使用
    if ready_file.exists() and config_exists and weight_exists:

        print(f"[模型] 使用本地模型：{model_name}")

        return str(local_path)

    # 下载模型
    print(f"[模型] 开始下载：{model_name}")

    local_path.mkdir(
        parents=True,
        exist_ok=True
    )

    snapshot_download(
        model_id=MODEL_CONFIG[model_name],
        local_dir=str(local_path)
    )

    # 标记模型下载完成
    ready_file.touch()

    print(f"[模型] 下载完成：{local_path}")

    return str(local_path)


# ============================================================
# 6. 加载 FunASR 模型
# ============================================================

def load_model(enable_speaker: bool = True, *, model_paths=None, punctuation=True):
    """
    初始化语音识别模型。

    包含：
    1. Paraformer 中文语音识别
    2. FSMN-VAD 语音检测
    3. CT-Punc 标点恢复
    4. CAM++ 说话人区分
    """

    print("\n" + "=" * 60)
    print("正在初始化 FunASR 模型")
    print("=" * 60)

    start_time = time.time()

    # 设置 PyTorch CPU 线程数量
    torch.set_num_threads(NCPU)

    # 获取本地模型路径
    model_paths = model_paths or {}

    def selected(name):
        return model_paths.get(name) or get_model_path(name)

    model_kwargs = {
        "model": selected("paraformer-zh"),

        "vad_model": selected("fsmn-vad"),

        "device": DEVICE,

        "ncpu": NCPU,

        "disable_update": True,

        "trust_remote_code": False,

        "vad_kwargs": {
            "max_single_segment_time": MAX_SINGLE_SEGMENT_TIME
        }
    }

    if punctuation:
        model_kwargs["punc_model"] = selected("ct-punc")

    # 根据配置加载说话人模型
    if enable_speaker:

        model_kwargs["spk_model"] = selected("cam++")

        print("[模型] 已启用说话人区分")

    else:

        print("[模型] 已关闭说话人区分")

    model = AutoModel(**model_kwargs)

    elapsed = time.time() - start_time

    print("\n" + "-" * 60)
    print(f"模型初始化完成，耗时：{elapsed:.2f} 秒")
    print(f"推理设备：{DEVICE}")
    print(f"CPU 线程数：{NCPU}")
    print(f"说话人区分：{enable_speaker}")
    print("-" * 60)

    return model


# ============================================================
# 7. 加载自定义热词
# ============================================================

def load_hotwords() -> str:
    """
    从 hotwords.txt 中读取专业术语热词。

    每行一个热词。
    自动去除空行、注释和重复内容。
    """

    if not HOTWORDS_FILE.exists():

        HOTWORDS_FILE.touch()

        print("[热词] 未配置热词")

        return ""

    words = []

    with HOTWORDS_FILE.open(
        "r",
        encoding="utf-8-sig"
    ) as file:

        for line in file:

            word = line.strip()

            if word and not word.startswith("#"):
                words.append(word)

    # 去重，同时保留原有顺序
    words = list(dict.fromkeys(words))

    print(f"[热词] 已加载 {len(words)} 个热词")

    return " ".join(words)


# ============================================================
# 8. 音频格式转换
# ============================================================

def convert_audio(
    input_path: Path,
    output_path: Path
) -> Path:
    """
    使用 FFmpeg 将音频统一转换为：

    采样率：16000 Hz
    声道数：1
    编码格式：PCM 16bit
    文件格式：WAV
    """

    print(f"[音频] 正在转换：{input_path.name}")

    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", str(input_path),
        "-vn",
        "-ac", "1",
        "-ar", "16000",
        "-c:a", "pcm_s16le",
        str(output_path)
    ]

    try:

        subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True
        )

    except FileNotFoundError:

        raise RuntimeError(
            "未找到 FFmpeg，请检查是否已经安装。"
        )

    except subprocess.CalledProcessError as error:

        raise RuntimeError(
            f"音频转换失败：{error.stderr}"
        ) from error

    if not output_path.exists():

        raise RuntimeError("音频转换失败，未生成 WAV 文件。")

    print("[音频] 格式转换完成")

    return output_path


# ============================================================
# 9. 获取音频时长
# ============================================================

def get_audio_duration(audio_path: Path) -> float:
    """
    使用 FFprobe 获取音频时长，单位：秒。
    """

    command = [
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(audio_path)
    ]

    try:

        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True
        )

        return float(result.stdout.strip())

    except Exception as error:

        print(f"[警告] 获取音频时长失败：{error}")

        return 0.0


# ============================================================
# 10. 时间格式转换
# ============================================================

def format_timestamp(milliseconds: float) -> str:
    """
    将毫秒转换为 HH:MM:SS 格式。
    """

    if milliseconds is None:
        return "--:--:--"

    total_seconds = max(
        0,
        int(milliseconds / 1000)
    )

    hours, remainder = divmod(
        total_seconds,
        3600
    )

    minutes, seconds = divmod(
        remainder,
        60
    )

    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


# ============================================================
# 11. 语音识别核心函数
# ============================================================

def transcribe(
    model,
    audio_path: Path,
    hotwords: str = "",
    *, progress=None
) -> dict:
    """
    执行语音识别。

    返回：
    text：完整识别文本
    sentence_info：分句结果
    timestamp：时间戳信息
    spk：说话人编号
    """

    print("[识别] 开始语音转文字")

    kwargs = {
        "input": str(audio_path),

        "batch_size_s": BATCH_SIZE_S,

        "batch_size_threshold_s": 30,

        "sentence_timestamp": True,

        "return_raw_text": False,

        "use_itn": True
    }

    # 加入自定义热词
    if hotwords:

        kwargs["hotword"] = hotwords

    if progress is not None:
        kwargs["desktop_speech_progress"] = progress
        kwargs["disable_pbar"] = True

    # 禁用梯度计算，降低推理开销
    with torch.inference_mode():

        result = model.generate(**kwargs)

    if not result:

        print("[警告] 模型未返回识别结果")

        return {}

    if not isinstance(result[0], dict):

        raise RuntimeError("FunASR 返回了非预期的数据格式")

    print("[识别] 语音识别完成")

    return result[0]


# ============================================================
# 12. 合并同一发言人的连续句子
# ============================================================

def merge_sentences(
    sentences: list,
    max_gap_ms: int = 1500,
    max_paragraph_chars: int = 500
) -> list:
    """
    将同一个发言人的连续短句合并。

    合并条件：
    1. 发言人相同
    2. 两段语音间隔不超过 max_gap_ms
    3. 合并后的文字不超过 max_paragraph_chars

    方便阅读长时间会议录音。
    """

    if not sentences:
        return []

    merged = []

    for sentence in sentences:

        content = sentence.get("text", "").strip()

        if not content:
            continue

        current = {
            "start": sentence.get("start"),
            "end": sentence.get("end"),
            "spk": sentence.get("spk"),
            "text": content
        }

        if not merged:

            merged.append(current)

            continue

        previous = merged[-1]

        same_speaker = (
            current["spk"] is not None
            and
            previous["spk"] == current["spk"]
        )

        if (
            current["start"] is not None
            and previous["end"] is not None
        ):

            gap = current["start"] - previous["end"]

        else:

            gap = float("inf")

        total_chars = (
            len(previous["text"])
            +
            len(current["text"])
        )

        if (
            same_speaker
            and 0 <= gap <= max_gap_ms
            and total_chars <= max_paragraph_chars
        ):

            previous["text"] += current["text"]

            previous["end"] = current["end"]

        else:

            merged.append(current)

    return merged


# ============================================================
# 13. 保存 TXT 文件
# ============================================================

def save_txt(
    result: dict,
    output_path: Path,
    source_file: Path,
    duration: float,
    elapsed: float,
    *, show_speakers=True, speaker_prefix="发言人", speaker_names=None,
    timestamps=True, plain=False
):
    """
    将语音识别结果保存为 UTF-8 TXT 文件。

    输出内容：
    1. 录音基本信息
    2. 发言人及时间戳
    3. 分段会议记录
    4. 完整纯文本
    """

    text = result.get("text", "")

    sentences = result.get("sentence_info") or []

    speaker_names = speaker_names or {}

    # 合并连续发言内容
    sentences = merge_sentences(sentences)

    lines = [
        "=" * 60,

        "会议录音转写记录",

        "=" * 60,

        "",

        f"录音文件：{source_file.name}",

        f"录音时长：{format_timestamp(duration * 1000)}",

        f"转写耗时：{elapsed:.2f} 秒",

        f"转写时间：{time.strftime('%Y-%m-%d %H:%M:%S')}",

        "",

        "=" * 60,

        "一、分段会议记录",

        "=" * 60,

        ""
    ]

    # 重新映射发言人编号
    speaker_map = {}

    if sentences and not plain:

        for sentence in sentences:

            start = sentence.get("start")
            end = sentence.get("end")

            speaker = sentence.get("spk")

            content = sentence.get("text", "").strip()

            if not content:
                continue

            start_time = format_timestamp(start)

            end_time = format_timestamp(end)

            # 统一发言人编号
            speaker_name = ""
            if show_speakers and speaker is not None:

                if speaker not in speaker_map:

                    speaker_map[speaker] = len(speaker_map) + 1

                number = speaker_map[speaker]
                speaker_name = speaker_names.get(str(number), f"{speaker_prefix}{number}")

            header = [f"[{start_time} - {end_time}]"] if timestamps else []
            if speaker_name:
                header.append(speaker_name)
            if header:
                lines.append(" ".join(header))

            lines.append(content)

            lines.append("")

    else:

        lines.append(
            text or "未识别到有效语音。"
        )

        lines.append("")

    # 添加完整纯文本
    lines.extend([
        "=" * 60,

        "二、完整纯文本",

        "=" * 60,

        "",

        text or "未识别到有效语音。",

        ""
    ])

    # 添加发言人数统计
    if speaker_map:

        lines.extend([
            "=" * 60,

            f"模型识别出的发言人数：{len(speaker_map)}",

            "注：发言人编号为自动聚类结果，仅供参考。",

            "=" * 60
        ])

    # 创建输出目录
    output_path.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    # 同目录写临时文件，完成后再替换目标。
    payload = (text or "未识别到有效语音。") if plain else "\n".join(lines)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=output_path.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(payload)
            temporary.close()
            temporary_path.replace(output_path)
        finally:
            temporary_path.unlink(missing_ok=True)

    print(f"[输出] TXT 文件已保存：{output_path}")


# ============================================================
# 14. 生成输出文件路径
# ============================================================

def get_output_path(input_path: Path) -> Path:
    """
    生成 TXT 输出路径，避免覆盖已有文件。
    """

    output_path = OUTPUT_DIR / f"{input_path.stem}.txt"

    index = 1

    while output_path.exists():

        output_path = (
            OUTPUT_DIR / f"{input_path.stem}_{index}.txt"
        )

        index += 1

    return output_path


# ============================================================
# 15. 处理单个录音文件
# ============================================================

def process_audio(
    model,
    input_path: Path,
    hotwords: str = "",
    *, output_path: Path | None = None, export_options=None, sense_voice=False, progress=None
) -> Path:
    """
    完整处理流程：

    1. 检查录音文件
    2. 转换音频格式
    3. 获取音频时长
    4. 执行语音识别
    5. 保存 TXT 文件
    6. 自动删除临时文件
    """

    input_path = Path(input_path).resolve()

    if not input_path.is_file():

        raise FileNotFoundError(
            f"录音文件不存在：{input_path}"
        )

    if input_path.suffix.lower() not in SUPPORTED_FORMATS:

        raise ValueError(
            f"不支持的文件格式：{input_path.suffix}"
        )

    output_path = output_path or get_output_path(input_path)
    if output_path.resolve() == input_path:
        raise ValueError("输出路径不能覆盖音频源文件")

    print("\n" + "=" * 60)
    print(f"正在处理：{input_path.name}")
    print("=" * 60)

    start_time = time.time()

    # 创建临时目录
    # 处理完成后自动删除
    with tempfile.TemporaryDirectory(
        prefix="funasr_"
    ) as temp_dir:

        wav_path = Path(temp_dir) / "audio.wav"

        if progress is not None:
            progress("converting")

        # 转换音频
        convert_audio(
            input_path,
            wav_path
        )

        # 获取音频时长
        duration = get_audio_duration(wav_path)

        print(
            f"[音频] 录音时长："
            f"{format_timestamp(duration * 1000)}"
        )

        if progress is not None:
            progress("detecting")

        # 执行语音识别
        result = transcribe(
            model=model,
            audio_path=wav_path,
            hotwords=hotwords,
            progress=progress
        )

        if progress is not None:
            progress("organizing")

        if sense_voice:
            import re

            def clean(text):
                return re.sub(r"<\|[^|]*\|>", "", text).strip()

            result["text"] = clean(result.get("text", ""))
            for sentence in result.get("sentence_info") or []:
                sentence["text"] = clean(sentence.get("text", ""))

        elapsed = time.time() - start_time

        # 保存识别结果
        save_txt(
            result=result,

            output_path=output_path,

            source_file=input_path,

            duration=duration,

            elapsed=elapsed,
            **(export_options or {})
        )

    print("\n" + "-" * 60)
    print("语音识别完成")
    print(f"录音时长：{duration:.2f} 秒")
    print(f"处理耗时：{elapsed:.2f} 秒")

    if duration > 0:

        rtf = elapsed / duration

        print(f"实时率 RTF：{rtf:.4f}")

        if elapsed > 0:

            print(f"处理速度：{duration / elapsed:.2f} 倍实时")

    print(f"输出文件：{output_path}")
    print("-" * 60)

    return output_path


# ============================================================
# 16. 获取待识别录音文件
# ============================================================

def get_audio_files(directory: Path) -> list[Path]:
    """
    获取指定目录下所有支持的录音文件。
    """

    if not directory.exists():

        return []

    return sorted(
        file
        for file in directory.iterdir()
        if file.is_file()
        and file.suffix.lower() in SUPPORTED_FORMATS
    )


# ============================================================
# 17. 主程序
# ============================================================

def main():

    parser = argparse.ArgumentParser(
        description="FunASR 本地会议录音转文字工具"
    )

    parser.add_argument(
        "audio",
        nargs="?",
        default=None,
        help="指定需要识别的录音文件或文件夹路径"
    )

    parser.add_argument(
        "--no-speaker",
        action="store_true",
        help="关闭说话人区分，仅执行语音识别"
    )

    parser.add_argument("-o", "--output", type=Path, help="单个音频的 TXT 保存路径")
    args = parser.parse_args()
    if args.output and (not args.audio or not Path(args.audio).expanduser().is_file()):
        parser.error("--output 需要指定一个音频文件")
    if args.output and args.output.suffix.lower() != ".txt":
        parser.error("--output 必须以 .txt 结尾")

    enable_speaker = (
        ENABLE_SPEAKER and not args.no_speaker
    )

    print("\n" + "=" * 60)
    print("FunASR 本地会议录音转文字系统")
    print("=" * 60)

    print(f"项目目录：{BASE_DIR}")
    print(f"模型目录：{MODEL_DIR}")
    print(f"录音目录：{AUDIO_DIR}")
    print(f"输出目录：{OUTPUT_DIR}")
    print(f"推理设备：{DEVICE}")
    print(f"CPU 线程：{NCPU}")
    print(f"说话人区分：{enable_speaker}")

    # 获取待处理录音
    if args.audio:

        input_path = (
            Path(args.audio)
            .expanduser()
            .resolve()
        )

        if input_path.is_file():

            audio_files = [input_path]

        elif input_path.is_dir():

            audio_files = get_audio_files(input_path)

        else:

            print(f"[错误] 路径不存在：{input_path}")

            return 1

    else:

        audio_files = get_audio_files(AUDIO_DIR)

    # 检查是否存在录音
    if not audio_files:

        print("\n未找到待识别的录音文件。")

        print(f"请将会议录音放入：{AUDIO_DIR}")

        return 0

    print(f"\n共发现 {len(audio_files)} 个录音文件")

    # 整个处理过程中只加载一次模型
    try:

        model = load_model(
            enable_speaker=enable_speaker
        )

    except Exception as error:

        print(f"[错误] 模型初始化失败：{error}")

        traceback.print_exc()

        return 1

    # 加载热词
    hotwords = load_hotwords()

    success_count = 0
    failed_count = 0

    failed_files = []

    total_start_time = time.time()

    # 批量处理录音
    for index, audio_file in enumerate(
        audio_files,
        start=1
    ):

        print(
            f"\n当前处理进度："
            f"{index}/{len(audio_files)}"
        )

        try:

            process_audio(
                model=model,

                input_path=audio_file,

                hotwords=hotwords,
                output_path=args.output.expanduser() if args.output else None
            )

            success_count += 1

        except KeyboardInterrupt:

            print("\n[提示] 用户终止了识别任务")

            return 130

        except Exception as error:

            failed_count += 1

            failed_files.append(audio_file.name)

            print(f"[错误] {audio_file.name} 处理失败")

            print(f"[错误] {error}")

            traceback.print_exc()

    total_elapsed = time.time() - total_start_time

    print("\n" + "=" * 60)
    print("全部录音处理结束")
    print("=" * 60)

    print(f"成功数量：{success_count}")
    print(f"失败数量：{failed_count}")
    print(f"总处理耗时：{total_elapsed:.2f} 秒")
    print(f"结果保存目录：{OUTPUT_DIR}")

    if failed_files:

        print("\n处理失败的文件：")

        for filename in failed_files:

            print(f"  - {filename}")

    print("=" * 60)

    return 1 if failed_count else 0


# ============================================================
# 18. 程序入口
# ============================================================

if __name__ == "__main__":

    raise SystemExit(main())
