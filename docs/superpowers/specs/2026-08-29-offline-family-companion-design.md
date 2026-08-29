# Offline Family Companion Design

## Goal

Make the Android app usable without this project's server: recordings, speech
analysis, emotion labels, speaker identification, correction, and speaker
learning stay on the phone.  A user may explicitly send the current day's
transcript to an OpenAI-compatible model using their own key to receive a
family communication suggestion.

## Privacy Boundary

The mobile application must not call any SofterPlease backend endpoint, store
an account token, or require a family/login identity.  All audio, transcripts,
speaker embeddings, corrections, and conversation history are stored locally.
The only network request is a user-initiated daily-advice request to the
provider URL configured by that user.  The provider key is stored in platform
secure storage and is never displayed after saving.

## Local Analysis

The bundled Ten-VAD, SenseVoice, and 3D-Speaker models run on the device.
Analysis produces an ordered list of utterances, each with a time span,
transcript, raw/model emotion, normalized emotion label, session speaker
cluster, and optional speaker embedding.  Existing saved speaker centroids are
matched first; otherwise the app clusters utterances within the recording.

When a person is selected in the correction UI, the selected utterance becomes
that person.  Its embedding is incorporated into that local person's centroid
with a weighted running average.  A newly named person receives an initial
centroid.  This makes future recordings improve without uploading voice data.

## Data Model and Storage

`LocalConversation` stores an audio path, creation time, duration, analysis
state, and its utterances.  `LocalUtterance` stores displayable analysis data
and an optional base64 encoding of its Float32 embedding.  `SpeakerProfile`
stores a stable identifier, local display name, embedding centroid, sample
count, and update time.  JSON in SharedPreferences stores conversations and
profiles; recordings remain app-local files.  The store retains the latest 100
conversations and never deletes audio automatically in this release.

`LlmSettings` stores provider base URL and model name in local preferences;
the API key is stored only in Flutter secure storage.  `DailyAdvice` is stored
locally with date, content, and source conversation IDs.

## User Experience

The app has three concise bottom tabs:

1. **记录**: model readiness, a single primary record/stop control, latest
   local result, and a compact privacy statement.
2. **对话**: local conversation cards and a detail view containing ordered
   utterances.  Each utterance shows speaker and emotion and opens a correction
   sheet to select or create a local person.
3. **家庭**: local speaker profiles, direct daily-advice control and result,
   provider/key settings, about, and signed-update status.

No login, cloud dashboard, backend health indicator, remote family members, or
server reports are shown in the mobile app.

## Direct LLM Advice

The daily-advice action only collects conversations created on the selected
local calendar day.  It sends a short Chinese system prompt and the ordered
speaker-attributed transcripts to `{baseUrl}/chat/completions`.  The default is
the OpenAI-compatible `https://api.openai.com/v1` endpoint and a configurable
model name.  Missing key, empty transcript, invalid response, and connection
errors receive clear on-device messages.  Advice is never auto-sent or
scheduled in the background.

## Compatibility and Verification

Android remains the release target; the Flutter UI remains portable.  The APK
continues to package the four local model assets through the existing GitHub
Actions workflow.  Unit tests cover speaker matching, centroid update,
conversation serialization, daily transcript selection, and advice response
decoding.  Widget tests cover the offline shell.  The release is independently
checked for Actions completion, APK signature/digest, bundled assets, and
signed update manifest.  Physical-device recording and inference must be
reported separately unless performed on a real device.
