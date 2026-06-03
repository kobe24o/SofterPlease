# CAiRE Speech Emotion Recognition

The backend uses `CAiRE/SER-wav2vec2-large-xlsr-53-eng-zho-all-age` when `EMOTION_BACKEND=caire`.

- Source model: https://huggingface.co/CAiRE/SER-wav2vec2-large-xlsr-53-eng-zho-all-age
- Training scripts: https://github.com/HLTCHKUST/elderly_ser
- License: `cc-by-sa-4.0`
- Required input: mono speech resampled to 16 kHz

CAiRE is a multi-label emotion model with this label order from the training code:

```text
sadness, fear, angry, happiness, disgust, neutral, surprise,
positive, negative, excitement, frustrated, other, unknown
```

SofterPlease maps those probabilities to the product value:

- `-1`: negative emotion is dominant
- `0`: neutral is dominant or the positive/negative margin is small
- `1`: positive emotion is dominant

The API still returns `anger_score` for backward-compatible gauges and feedback thresholds.
The new primary field for the user's requirement is `emotion_value`.

## Local CUDA Run

This workstation was verified with:

- NVIDIA driver CUDA runtime: `12.4`
- PyTorch: `2.6.0+cu124`
- GPU: `Quadro M2000M`

Install the CUDA wheel when Python reports a CPU-only torch build:

```powershell
python -m pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
```

Start the backend from `backend/`:

```powershell
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

The model loads lazily on the first analysis request. To force-load it before using the phone app:

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8000/v1/system/emotion-model/load -Method POST -UseBasicParsing
nvidia-smi
```

Check runtime status:

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8000/v1/system/info -UseBasicParsing
```

`emotion_model.device` should be `cuda`, `torch_cuda_available` should be `true`, and `caire_loaded` should become `true` after preload or first analysis.
