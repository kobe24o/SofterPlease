"""
SofterPlease 情绪识别引擎

提供语音情绪识别、声纹识别、实时反馈生成等功能
"""

from .emotion_analyzer import EmotionAnalyzer
from .voice_recognition import VoiceRecognizer
from .feedback_generator import FeedbackGenerator
from .audio_processor import AudioProcessor

__all__ = [
    "EmotionAnalyzer",
    "VoiceRecognizer", 
    "FeedbackGenerator",
    "AudioProcessor",
]
