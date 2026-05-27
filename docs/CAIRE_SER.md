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
