"""Expose per-recording VAD and speech-duration progress in the bundled FunASR."""
from pathlib import Path
import sys

target = Path(sys.argv[1])
source = target.read_text(encoding="utf-8")
marker = "desktop_speech_progress"
if marker not in source:
    start = source.index("    def inference_with_vad(")
    prefix, body = source[:start], source[start:]

    def replace_once(old, new):
        global body
        if body.count(old) != 1:
            raise RuntimeError(f"Unexpected FunASR implementation near {old!r}")
        body = body.replace(old, new, 1)

    replace_once(
        '        kwargs = self.kwargs\n        # step.1: compute the vad model',
        '        desktop_speech_progress = cfg.pop("desktop_speech_progress", None)\n'
        '        kwargs = self.kwargs\n        # step.1: compute the vad model',
    )
    replace_once(
        '        # step.2 compute asr model',
        '        total_speech_ms = 0\n'
        '        processed_speech_ms = 0\n'
        '        if desktop_speech_progress is not None:\n'
        '            total_speech_ms = sum(\n'
        '                int(end) - int(start) for result in res for start, end in result["value"]\n'
        '            )\n'
        '            desktop_speech_progress("recognizing", 0, total_speech_ms)\n\n'
        '        # step.2 compute asr model',
    )
    replace_once(
        '                beg_idx = end_idx\n                end_idx += 1',
        '                if desktop_speech_progress is not None:\n'
        '                    processed_speech_ms += sum(\n'
        '                        int(segment[1]) - int(segment[0])\n'
        '                        for segment, _ in sorted_data[beg_idx:end_idx]\n'
        '                    )\n'
        '                    desktop_speech_progress("recognizing", processed_speech_ms, total_speech_ms)\n'
        '                beg_idx = end_idx\n                end_idx += 1',
    )
    replace_once(
        '            # end_asr_total = time.time()',
        '            if desktop_speech_progress is not None and i == len(res) - 1:\n'
        '                desktop_speech_progress("organizing", 0, 0)\n\n'
        '            # end_asr_total = time.time()',
    )
    target.write_text(prefix + body, encoding="utf-8")
