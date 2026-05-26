from fastapi import APIRouter, UploadFile, File, HTTPException
from transformers import pipeline
import tempfile
import torch
import os
import shutil
from pathlib import Path
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor


def ensure_ffmpeg_on_path() -> None:
    if shutil.which("ffmpeg"):
        return

    try:
        import imageio_ffmpeg
    except ImportError:
        return

    ffmpeg_path = Path(imageio_ffmpeg.get_ffmpeg_exe())
    shim_dir = Path(tempfile.gettempdir()) / "drwisper-ffmpeg-bin"
    shim_dir.mkdir(exist_ok=True)
    shim_path = shim_dir / "ffmpeg"

    if not shim_path.exists():
        shim_path.symlink_to(ffmpeg_path)

    os.environ["PATH"] = f"{shim_dir}{os.pathsep}{os.environ.get('PATH', '')}"


ensure_ffmpeg_on_path()

AutoModelForSpeechSeq2Seq.from_pretrained("openai/whisper-large-v3-turbo")
AutoProcessor.from_pretrained("openai/whisper-large-v3-turbo") 


router = APIRouter()

device = 0 if torch.cuda.is_available() else -1

torch_dtype = torch.float16 if torch.cuda.is_available() else torch.float32

asr_pipeline = pipeline(
    task="automatic-speech-recognition",
    model="openai/whisper-large-v3-turbo",
    torch_dtype=torch_dtype,
    device=device,
)


ALLOWED_AUDIO_TYPES = {
    "audio/wav",
    "audio/mpeg",
    "audio/mp3",
    "audio/webm",
    "audio/ogg",
    "audio/flac",
    "audio/x-wav",
}

@router.post("/")
async def audioToText(file: UploadFile = File(...), model="openai/whisper-large-v3-turbo"):
    # basic validation 
    if file.content_type not in ALLOWED_AUDIO_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"unsupported file type: {file.content_type}"
            )
    
    suffix = os.path.splitext(file.filename or "")[1] or ".wav"

    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_audio:
        temp_audio.write(await file.read())
        temp_audio_path = temp_audio.name

    try:
        result = asr_pipeline(
            temp_audio_path,
            return_timestamps=True,
            generate_kwargs={
                "language": "english",
                "task": "transcribe",
            },
        )

        return {
            "text": result["text"]
        }
    except Exception as error:
        raise HTTPException(
            status_code=500,
            detail=f"transcription failed: {error}",
        ) from error

    finally:
        os.remove(temp_audio_path)
