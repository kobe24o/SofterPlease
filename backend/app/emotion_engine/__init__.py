"""
SofterPlease 情绪识别引擎

提供语音情绪识别、声纹识别、实时反馈生成等功能
"""

from .emotion_analyzer import EmotionAnalyzer
from .voice_recognition import VoiceRecognizer
from .feedback_generator import FeedbackGenerator
from .audio_processor import AudioProcessor
from .text_emotion_model import TextEmotionModel
from .multimodal_emotion_model import MultimodalEmotionModel

__all__ = [
    "EmotionAnalyzer",
    "VoiceRecognizer", 
    "FeedbackGenerator",
    "AudioProcessor",
    "TextEmotionModel",
    "MultimodalEmotionModel",
]
