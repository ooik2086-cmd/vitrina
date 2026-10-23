"""The seller's own video of a pair: up to a minute, as filmed on a phone, made small enough to play on a weak line.

The upload is checked at once (a video, at most LISTING_VIDEO_SECONDS long) and then, apart from the request, encoded
to 720p H.264 with its index at the front (so it starts playing before it has all come down), its metadata (phone,
place, time) dropped, with a poster frame for the page to show before it is played."""
from __future__ import annotations

import json
import logging
import resource
import shutil
import subprocess
import threading
from pathlib import Path

from .errors import ApiError
from .storage import VideoUnavailable

log = logging.getLogger("vitrina.video")

LISTING_VIDEO_SECONDS = 60
MIN_VIDEO_SECONDS = 2  # shorter says nothing about the pair (a tap on record by mistake)
# A minute filmed at 1080p is about 130 MB on most phones; 4K is refused with a word to film in 1080p or 720p.
VIDEO_UPLOAD_BYTES = 200 * 1024 * 1024
OUT_SIDE = 720  # the short side; a phone screen shows no more of it in the listing's stage
OUT_CAP = 40 * 1024 * 1024  # a minute at 720p within the bitrate cap below is about 15 MB; anything near this is wrong
ENCODE_CPU_SECONDS = 600  # a minute of 1080p at the veryfast preset takes well under this on two cores
PROBE_SECONDS = 15
_encode_slots = threading.Semaphore(1)  # one encode per API process at a time: it takes both cores while it runs
# Videos waiting for that slot, each holding a worker thread the API shares: a few at most, the rest asked again later.
VIDEO_QUEUE = 3
queue_places = threading.BoundedSemaphore(VIDEO_QUEUE)


def _limit(cpu: int, size: int):
    def apply() -> None:
        resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
        resource.setrlimit(resource.RLIMIT_FSIZE, (size, size))
        resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))
    return apply


def _tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise VideoUnavailable(f"{name} not found")
    return path


def probe_seconds(src: Path) -> float:
    """How long the video is. 415 for a file that is not a video ffprobe can read, 422 for one too long or short."""
    try:
        run = subprocess.run(
            [_tool("ffprobe"), "-v", "error", "-protocol_whitelist", "file", "-show_entries",
             "format=duration:stream=codec_type", "-of", "json", "-f", "mov", str(src)],
            capture_output=True, timeout=PROBE_SECONDS, preexec_fn=_limit(PROBE_SECONDS, 1 << 20))
    except subprocess.TimeoutExpired as exc:
        raise VideoUnavailable("probe timeout") from exc
    except OSError as exc:
        raise VideoUnavailable(str(exc)) from exc
    try:
        info = json.loads(run.stdout or b"{}")
        seconds = float(info["format"]["duration"])
    except (ValueError, KeyError, TypeError):
        seconds = None
    if run.returncode != 0 or seconds is None or not any(
            s.get("codec_type") == "video" for s in info.get("streams", [])):
        raise ApiError(415, "video_unreadable")
    # A phone's one-minute limit stops a little after 60 s.
    if seconds > LISTING_VIDEO_SECONDS + 1:
        raise ApiError(422, "video_too_long", f"at most {LISTING_VIDEO_SECONDS} seconds")
    if seconds < MIN_VIDEO_SECONDS:
        raise ApiError(422, "video_too_short", f"at least {MIN_VIDEO_SECONDS} seconds")
    return seconds


def encode(src: Path, work: Path) -> tuple[bytes, bytes]:
    """The video at 720p (never larger than filmed) and a poster frame, as (mp4, jpeg). Waits for a free slot.
    Raises VideoUnavailable when the server cannot run ffmpeg, ApiError 415 when the file does not encode."""
    ffmpeg = _tool("ffmpeg")
    out, poster = work / "out.mp4", work / "poster.jpg"
    # The short side down to 720, whichever way the phone was held (ffmpeg turns it upright first).
    scale = (f"scale='if(gt(iw,ih),-2,min({OUT_SIDE},iw))':'if(gt(iw,ih),min({OUT_SIDE},ih),-2)',"
             "format=yuv420p")
    with _encode_slots:
        try:
            run = subprocess.run(
                # "-f mov" (mp4, mov, 3gp, as phones record): a playlist or concat file never opens other files.
                [ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-protocol_whitelist", "file", "-f", "mov",
                 "-i", str(src),
                 "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1", "-map_chapters", "-1",
                 "-t", str(LISTING_VIDEO_SECONDS + 1), "-vf", scale, "-fpsmax", "30",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-maxrate", "2M", "-bufsize", "4M",
                 "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-threads", "2", "-fflags", "+bitexact",
                 "-movflags", "+faststart", "-fs", str(OUT_CAP), str(out)],
                capture_output=True, timeout=ENCODE_CPU_SECONDS,
                preexec_fn=_limit(ENCODE_CPU_SECONDS, OUT_CAP + (1 << 20)))
            if run.returncode == 0 and out.exists() and 0 < out.stat().st_size < OUT_CAP:
                # A second in, past a dark first frame; from the encoded copy, so it matches what plays.
                subprocess.run(
                    [ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-protocol_whitelist", "file", "-ss", "1",
                     "-i", str(out), "-frames:v", "1", "-q:v", "4", "-update", "1", str(poster)],
                    capture_output=True, timeout=60, preexec_fn=_limit(60, 8 << 20))
        except subprocess.TimeoutExpired as exc:
            raise VideoUnavailable("encode timeout") from exc
        except OSError as exc:
            raise VideoUnavailable(str(exc)) from exc
    if run.returncode != 0 or not out.exists() or not 0 < out.stat().st_size < OUT_CAP or not poster.exists():
        log.info("listing video refused: exit %s, %s", run.returncode, run.stderr.decode(errors="replace")[-300:])
        raise ApiError(415, "video_unreadable")
    return out.read_bytes(), poster.read_bytes()
