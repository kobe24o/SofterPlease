import numpy as np

from app.conversation_service import ConversationService


def test_vad_splits_overlong_speech_to_model_limit():
    sample_rate = 16000
    service = ConversationService(max_segment_seconds=2.0)
    audio = np.full(sample_rate * 5, 0.2, dtype=np.float32)

    segments = service.split_audio(audio, sample_rate)

    assert len(segments) == 3
    assert all(len(segment.audio) <= sample_rate * 2 for segment in segments)
    assert segments[0].start_sample == 0
    assert segments[-1].end_sample == len(audio)


def test_embedding_clustering_keeps_similar_speakers_together():
    service = ConversationService()
    embeddings = [
        np.array([1.0, 0.0, 0.0]),
        np.array([0.99, 0.01, 0.0]),
        np.array([0.0, 1.0, 0.0]),
    ]

    labels = service.cluster_embeddings(embeddings)

    assert labels[0] == labels[1]
    assert labels[0] != labels[2]


def test_auto_speaker_matching_merges_clear_moderate_match():
    service = ConversationService()
    target = np.array([0.58, 0.0, 0.8146161], dtype=np.float32)
    profiles = {
        "spk_parent": np.array([1.0, 0.0, 0.0], dtype=np.float32),
        "spk_child": np.array([0.0, 1.0, 0.0], dtype=np.float32),
    }

    match = service.match_speaker_profile(
        target,
        profiles,
        auto_profile_ids={"spk_parent", "spk_child"},
    )

    assert match is not None
    assert match.speaker_id == "spk_parent"
    assert 0.55 < match.confidence < 0.60


def test_auto_speaker_matching_rejects_ambiguous_moderate_match():
    service = ConversationService()
    target = np.array([0.72, 0.694, 0.0], dtype=np.float32)
    profiles = {
        "spk_parent": np.array([1.0, 0.0, 0.0], dtype=np.float32),
        "spk_child": np.array([0.0, 1.0, 0.0], dtype=np.float32),
    }

    match = service.match_speaker_profile(
        target,
        profiles,
        auto_profile_ids={"spk_parent", "spk_child"},
    )

    assert match is None


def test_registered_voice_profile_still_requires_stronger_match():
    service = ConversationService()
    target = np.array([0.58, 0.8146161, 0.0], dtype=np.float32)
    profiles = {"family_member": np.array([1.0, 0.0, 0.0], dtype=np.float32)}

    match = service.match_speaker_profile(target, profiles, auto_profile_ids=set())

    assert match is None


def test_update_speaker_centroid_uses_sample_count():
    service = ConversationService()
    old = np.array([1.0, 0.0, 0.0], dtype=np.float32)
    new = np.array([0.0, 1.0, 0.0], dtype=np.float32)

    updated = service.update_speaker_centroid(old, new, existing_sample_count=3)

    expected = np.array([3.0, 1.0, 0.0], dtype=np.float32)
    expected /= np.linalg.norm(expected)
    assert np.allclose(updated, expected)


def test_cosine_similarity_rejects_incompatible_embeddings():
    service = ConversationService()
    assert service.cosine_similarity([1, 0], [1, 0]) == 1.0
    assert service.cosine_similarity([1, 0], [1, 0, 0]) == 0.0
