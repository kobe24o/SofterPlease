"""
情绪分析器 - 分析语音中的情绪状态

支持多维度情绪分析：
- 愤怒/激动程度 (anger_score)
- 情感效价 (valence)
- 唤醒度 (arousal)
- 压力指数 (stress)
- 不耐烦指数 (impatience)
"""

from __future__ import annotations

import os
import logging
import numpy as np
from typing import Dict, Any, Optional
from dataclasses import dataclass, field
import librosa
import soundfile as sf
import tempfile
import torch
import torch.nn as nn

from .text_emotion_model import TextEmotionModel
from .multimodal_emotion_model import MultimodalEmotionModel
from .tri_class_emotion_model import TriClassEmotionModel

# 配置日志
logger = logging.getLogger(__name__)


@dataclass
class EmotionAnalysisResult:
    """情绪分析结果"""
    anger_score: float  # 0-1, 愤怒程度
    emotion_level: str  # calm, mild, moderate, high, extreme
    emotion_value: int  # -1 负向, 0 中性, 1 正向
    
    # 多维度情绪
    valence: float      # -1 to 1, 负面到正面
    arousal: float      # 0 to 1, 平静到激动
    dominance: float    # 0 to 1, 被动到主动
    stress: float       # 0 to 1, 压力指数
    impatience: float   # 0 to 1, 不耐烦指数
    
    # 声学特征
    acoustic_features: Dict[str, float]
    
    # 置信度
    confidence: float
    model_backend: str = "rule"
    raw_emotions: Dict[str, float] = field(default_factory=dict)
    transcript: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "anger_score": round(self.anger_score, 4),
            "emotion_level": self.emotion_level,
            "emotion_value": self.emotion_value,
            "emotion_dimensions": {
                "valence": round(self.valence, 4),
                "arousal": round(self.arousal, 4),
                "dominance": round(self.dominance, 4),
                "stress": round(self.stress, 4),
                "impatience": round(self.impatience, 4),
            },
            "acoustic_features": self.acoustic_features,
            "confidence": round(self.confidence, 4),
            "model_backend": self.model_backend,
            "raw_emotions": {
                label: round(score, 4) for label, score in self.raw_emotions.items()
            },
            "transcript": self.transcript,
        }


class EmotionCNN(nn.Module):
    """轻量级CNN情绪识别模型"""
    
    def __init__(self, input_channels: int = 1, num_classes: int = 5):
        super().__init__()
        
        self.features = nn.Sequential(
            # Conv Block 1
            nn.Conv2d(input_channels, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2, 2),
            nn.Dropout(0.2),
            
            # Conv Block 2
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2, 2),
            nn.Dropout(0.3),
            
            # Conv Block 3
            nn.Conv2d(64, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.AdaptiveAvgPool2d((4, 4)),
            nn.Dropout(0.4),
        )
        
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(128 * 4 * 4, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(0.5),
            nn.Linear(256, num_classes),
            nn.Sigmoid(),
        )
    
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.features(x)
        x = self.classifier(x)
        return x


class EmotionAnalyzer:
    """
    情绪分析器
    
    结合声学特征和语义分析来评估情绪状态
    """
    
    # 情绪等级阈值
    EMOTION_LEVELS = [
        (0.0, 0.3, "calm"),
        (0.3, 0.5, "mild"),
        (0.5, 0.7, "moderate"),
        (0.7, 0.85, "high"),
        (0.85, 1.0, "extreme"),
    ]

    CAIRE_MODEL_ID = "CAiRE/SER-wav2vec2-large-xlsr-53-eng-zho-all-age"
    SENSEVOICE_MODEL_ID = "iic/SenseVoiceSmall"
    EMOTION2VEC_MODEL_ID = "iic/emotion2vec_plus_large"
    CAIRE_LABELS = [
        "sadness", "fear", "angry", "happiness", "disgust", "neutral", "surprise",
        "positive", "negative", "excitement", "frustrated", "other", "unknown",
    ]
    POSITIVE_LABELS = {"happiness", "positive", "excitement"}
    NEGATIVE_LABELS = {"sadness", "fear", "angry", "disgust", "negative", "frustrated"}
    
    # 愤怒关键词（中文）
    ANGER_KEYWORDS = [
        "生气", "愤怒", "恼火", "烦躁", "讨厌", "恨", "滚", "闭嘴",
        "烦死了", "气死我了", "受不了", "够了", "别说了", "你懂什么",
        "总是", "永远", "从来不", "为什么总是", "怎么又是",
    ]
    
    # 不耐烦关键词
    IMPATIENCE_KEYWORDS = [
        "快点", "赶紧", " hurry", "快点说", "长话短说", "别废话",
        "直接说", "说重点", "没时间", "忙着呢",
    ]
    
    def __init__(self, model_path: Optional[str] = None, device: str = "auto"):
        device = os.getenv("EMOTION_DEVICE", device).strip().lower()
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        self.device = torch.device(device)
        self.sample_rate = 16000
        self.n_mels = 128
        self.hop_length = 512
        self.n_fft = 2048
        self.backend = os.getenv("EMOTION_BACKEND", "sensevoice").strip().lower()
        self.caire_model_id = os.getenv("CAIRE_MODEL_ID", self.CAIRE_MODEL_ID)
        self.sensevoice_model_id = os.getenv("SENSEVOICE_MODEL_ID", self.SENSEVOICE_MODEL_ID)
        self.emotion2vec_model_id = os.getenv("EMOTION2VEC_MODEL_ID", self.EMOTION2VEC_MODEL_ID)
        self._emotion2vec_model = None
        self._emotion2vec_load_attempted = False
        self._emotion2vec_load_error = None
        self._caire_model = None
        self._caire_feature_extractor = None
        self._caire_load_attempted = False
        self._caire_load_error = None
        self._sensevoice_model = None
        self._sensevoice_load_attempted = False
        self._sensevoice_load_error = None
        logger.info(
            "Emotion backend=%s device=%s torch_cuda_available=%s",
            self.backend,
            self.device,
            torch.cuda.is_available(),
        )
        
        # 初始化模型（如果没有预训练模型，使用规则引擎）
        self.model = None
        self.use_ml_model = False
        
        # 文本情绪模型（可选）
        self.text_model = None
        text_model_path = os.getenv("TEXT_EMOTION_MODEL_PATH", "models/emotion_text_nb_v1.json")
        if text_model_path and os.path.exists(text_model_path):
            try:
                self.text_model = TextEmotionModel.load(text_model_path)
                logger.info(f"Loaded text emotion model from {text_model_path}")
            except Exception as e:
                logger.warning(f"Failed to load text emotion model from {text_model_path}: {e}")

        # 多模态模型（文本+声学，可选）
        self.multimodal_model = None
        multimodal_model_path = os.getenv("MULTIMODAL_EMOTION_MODEL_PATH", "models/multimodal_emotion_v1.json")
        if multimodal_model_path and os.path.exists(multimodal_model_path):
            try:
                self.multimodal_model = MultimodalEmotionModel.load(multimodal_model_path)
                logger.info(f"Loaded multimodal emotion model from {multimodal_model_path}")
            except Exception as e:
                logger.warning(f"Failed to load multimodal emotion model from {multimodal_model_path}: {e}")

        self.tri_class_model = None
        self.tri_class_model_path = None
        tri_class_model_path = os.getenv(
            "TRICLASS_EMOTION_MODEL_PATH",
            "models/debug_emotion_calibrator_v1.json",
        )
        if tri_class_model_path and os.path.exists(tri_class_model_path):
            try:
                self.tri_class_model = TriClassEmotionModel.load(tri_class_model_path)
                self.tri_class_model_path = tri_class_model_path
                logger.info("Loaded tri-class emotion calibrator from %s", tri_class_model_path)
            except Exception as e:
                logger.warning("Failed to load tri-class emotion calibrator from %s: %s", tri_class_model_path, e)

        # 优先使用传入的路径，其次从环境变量读取
        if model_path is None:
            model_path = os.getenv('EMOTION_MODEL_PATH', 'models/emotion_cnn.pth')
        
        if self.backend == "local_cnn" and model_path and os.path.exists(model_path):
            try:
                self.model = EmotionCNN().to(self.device)
                self.model.load_state_dict(torch.load(model_path, map_location=self.device))
                self.model.eval()
                self.use_ml_model = True
                logger.info(f"Successfully loaded ML model from {model_path}")
            except Exception as e:
                logger.warning(f"Failed to load ML model from {model_path}: {e}")
                logger.info("Falling back to rule-based engine")
        elif self.backend == "local_cnn":
            if model_path:
                logger.warning(f"Model weights not found at {model_path}, using rule-based engine")
            else:
                logger.info("No model path provided, using rule-based engine")

    def get_status(self) -> Dict[str, Any]:
        """Return runtime model status for health checks and clients."""
        cuda_name = None
        if torch.cuda.is_available():
            try:
                cuda_name = torch.cuda.get_device_name(0)
            except Exception:
                cuda_name = "available"

        return {
            "backend": self.backend,
            "device": str(self.device),
            "torch_version": torch.__version__,
            "torch_cuda_available": torch.cuda.is_available(),
            "torch_cuda_version": torch.version.cuda,
            "cuda_device": cuda_name,
            "emotion2vec_model_id": self.emotion2vec_model_id,
            "emotion2vec_loaded": self._emotion2vec_model is not None,
            "emotion2vec_load_attempted": self._emotion2vec_load_attempted,
            "emotion2vec_load_error": self._emotion2vec_load_error,
            "sensevoice_model_id": self.sensevoice_model_id,
            "sensevoice_loaded": self._sensevoice_model is not None,
            "sensevoice_load_attempted": self._sensevoice_load_attempted,
            "sensevoice_load_error": self._sensevoice_load_error,
            "caire_model_id": self.caire_model_id,
            "caire_loaded": self._caire_model is not None,
            "caire_load_attempted": self._caire_load_attempted,
            "caire_load_error": self._caire_load_error,
            "local_cnn_loaded": self.use_ml_model,
            "tri_class_calibrator_loaded": self.tri_class_model is not None,
            "tri_class_calibrator_version": self.tri_class_model.version if self.tri_class_model else None,
            "tri_class_calibrator_path": self.tri_class_model_path,
            "tri_class_calibrator_metrics": self.tri_class_model.metrics if self.tri_class_model else None,
            "fallback_backend": "rule",
        }

    def load_tri_class_calibrator(self, model_path: str, version: str | None = None) -> bool:
        try:
            model = TriClassEmotionModel.load(model_path)
            if version:
                model.version = version
            self.tri_class_model = model
            self.tri_class_model_path = str(model_path)
            logger.info("Activated tri-class emotion calibrator %s from %s", model.version, model_path)
            return True
        except Exception as exc:
            logger.exception("Failed to activate tri-class emotion calibrator from %s", model_path)
            return False

    def ensure_model_loaded(self) -> bool:
        """Eagerly load the configured emotion model when supported."""
        if self.backend == "emotion2vec":
            return self._ensure_emotion2vec_model()
        if self.backend == "sensevoice":
            return self._ensure_sensevoice_model()
        if self.backend == "caire":
            return self._ensure_caire_model()
        return self.use_ml_model or self.backend == "rule"

    def _ensure_emotion2vec_model(self) -> bool:
        """Lazy-load FunASR emotion2vec."""
        if self._emotion2vec_model is not None:
            return True
        if self._emotion2vec_load_attempted:
            return False

        self._emotion2vec_load_attempted = True
        self._emotion2vec_load_error = None
        try:
            from funasr import AutoModel

            device = "cuda:0" if self.device.type == "cuda" and torch.cuda.is_available() else "cpu"
            self._emotion2vec_model = AutoModel(
                model=self.emotion2vec_model_id,
                trust_remote_code=True,
                device=device,
                disable_update=True,
            )
            logger.info("Loaded emotion2vec model: %s on %s", self.emotion2vec_model_id, device)
            return True
        except Exception as exc:
            self._emotion2vec_load_error = str(exc)
            logger.exception("Failed to load emotion2vec model, falling back to rules")
            self._emotion2vec_model = None
            return False

    def _ensure_sensevoice_model(self) -> bool:
        """Lazy-load Alibaba/FunAudioLLM SenseVoiceSmall."""
        if self._sensevoice_model is not None:
            return True
        if self._sensevoice_load_attempted:
            return False

        self._sensevoice_load_attempted = True
        self._sensevoice_load_error = None
        try:
            from funasr import AutoModel

            device = "cuda:0" if self.device.type == "cuda" and torch.cuda.is_available() else "cpu"
            self._sensevoice_model = AutoModel(
                model=self.sensevoice_model_id,
                trust_remote_code=True,
                device=device,
                disable_update=True,
            )
            logger.info("Loaded SenseVoice model: %s on %s", self.sensevoice_model_id, device)
            return True
        except Exception as exc:
            self._sensevoice_load_error = str(exc)
            logger.exception("Failed to load SenseVoice model, falling back to rules")
            self._sensevoice_model = None
            return False

    def _ensure_caire_model(self) -> bool:
        """延迟加载 CAiRE 模型，避免服务启动时阻塞或强依赖 transformers。"""
        if self._caire_model is not None and self._caire_feature_extractor is not None:
            return True
        if self._caire_load_attempted:
            return False

        self._caire_load_attempted = True
        self._caire_load_error = None
        try:
            from transformers import Wav2Vec2FeatureExtractor, Wav2Vec2ForSequenceClassification
            from transformers.modeling_outputs import SequenceClassifierOutput
            from torch.nn import BCEWithLogitsLoss

            class Wav2Vec2ForMultilabelSequenceClassification(Wav2Vec2ForSequenceClassification):
                def forward(
                    inner_self,
                    input_values,
                    attention_mask=None,
                    output_attentions=None,
                    output_hidden_states=None,
                    return_dict=None,
                    labels=None,
                    labels_mask=None,
                ):
                    return_dict = return_dict if return_dict is not None else inner_self.config.use_return_dict
                    output_hidden_states = True if inner_self.config.use_weighted_layer_sum else output_hidden_states

                    outputs = inner_self.wav2vec2(
                        input_values,
                        attention_mask=attention_mask,
                        output_attentions=output_attentions,
                        output_hidden_states=output_hidden_states,
                        return_dict=return_dict,
                    )
                    hidden_states = outputs.hidden_states if inner_self.config.use_weighted_layer_sum else outputs[0]
                    if inner_self.config.use_weighted_layer_sum:
                        hidden_states = torch.stack(hidden_states, dim=1)
                        norm_weights = nn.functional.softmax(inner_self.layer_weights, dim=-1)
                        hidden_states = (hidden_states * norm_weights.view(-1, 1, 1)).sum(dim=1)

                    hidden_states = inner_self.projector(hidden_states)
                    if attention_mask is None:
                        pooled_output = hidden_states.mean(dim=1)
                    else:
                        padding_mask = inner_self._get_feature_vector_attention_mask(
                            hidden_states.shape[1], attention_mask
                        )
                        hidden_states[~padding_mask] = 0.0
                        pooled_output = hidden_states.sum(dim=1) / padding_mask.sum(dim=1).view(-1, 1)

                    logits = inner_self.classifier(pooled_output)
                    loss = None
                    if labels is not None:
                        if labels_mask is None:
                            labels_mask = torch.ones_like(labels)
                        loss_fct = BCEWithLogitsLoss(weight=labels_mask.view(-1))
                        loss = loss_fct(logits.view(-1), labels.float().view(-1))

                    if not return_dict:
                        output = (logits,) + outputs[2:]
                        return ((loss,) + output) if loss is not None else output

                    return SequenceClassifierOutput(
                        loss=loss,
                        logits=logits,
                        hidden_states=outputs.hidden_states,
                        attentions=outputs.attentions,
                    )

            self._caire_feature_extractor = Wav2Vec2FeatureExtractor.from_pretrained(self.caire_model_id)
            self._caire_model = Wav2Vec2ForMultilabelSequenceClassification.from_pretrained(
                self.caire_model_id,
                num_labels=len(self.CAIRE_LABELS),
            ).to(self.device)
            self._caire_model.eval()
            logger.info("Loaded CAiRE SER model: %s", self.caire_model_id)
            return True
        except Exception as exc:
            self._caire_load_error = str(exc)
            logger.exception("Failed to load CAiRE SER model, falling back to rules")
            self._caire_model = None
            self._caire_feature_extractor = None
            return False
    
    def _extract_mel_spectrogram(self, audio: np.ndarray) -> np.ndarray:
        """提取梅尔频谱图"""
        mel_spec = librosa.feature.melspectrogram(
            y=audio,
            sr=self.sample_rate,
            n_mels=self.n_mels,
            hop_length=self.hop_length,
            n_fft=self.n_fft,
        )
        mel_spec_db = librosa.power_to_db(mel_spec, ref=np.max)
        return mel_spec_db
    
    def _extract_acoustic_features(self, audio: np.ndarray, sr: int) -> Dict[str, float]:
        """提取声学特征"""
        features = {}
        
        # 基频 (Pitch)
        pitches, magnitudes = librosa.piptrack(y=audio, sr=sr)
        pitch_values = pitches[magnitudes > np.median(magnitudes)]
        features["pitch_mean"] = float(np.mean(pitch_values)) if len(pitch_values) > 0 else 0.0
        features["pitch_std"] = float(np.std(pitch_values)) if len(pitch_values) > 0 else 0.0
        
        # 能量 (Energy/RMS)
        rms = librosa.feature.rms(y=audio)[0]
        features["energy_mean"] = float(np.mean(rms))
        features["energy_std"] = float(np.std(rms))
        
        # 过零率 (Zero Crossing Rate) - 反映音频的"尖锐"程度
        zcr = librosa.feature.zero_crossing_rate(y=audio)[0]
        features["zcr_mean"] = float(np.mean(zcr))
        
        # 语速估计 (基于音节检测)
        onset_env = librosa.onset.onset_strength(y=audio, sr=sr)
        tempo, _ = librosa.beat.beat_track(onset_envelope=onset_env, sr=sr)
        features["speaking_rate"] = float(tempo) / 60.0  # 转换为每秒音节数估计
        
        # 停顿比例
        intervals = librosa.effects.split(audio, top_db=20)
        speech_duration = sum(end - start for start, end in intervals) / sr
        total_duration = len(audio) / sr
        features["duration"] = float(total_duration)
        features["pause_ratio"] = 1.0 - (speech_duration / total_duration) if total_duration > 0 else 0.0
        
        # 频谱质心 (Spectral Centroid) - 亮度
        centroid = librosa.feature.spectral_centroid(y=audio, sr=sr)[0]
        features["spectral_centroid_mean"] = float(np.mean(centroid))
        
        # 频谱滚降 (Spectral Rolloff)
        rolloff = librosa.feature.spectral_rolloff(y=audio, sr=sr)[0]
        features["spectral_rolloff_mean"] = float(np.mean(rolloff))
        
        # MFCC特征 (前13个系数)
        mfccs = librosa.feature.mfcc(y=audio, sr=sr, n_mfcc=13)
        for i in range(13):
            features[f"mfcc_{i}_mean"] = float(np.mean(mfccs[i]))
            features[f"mfcc_{i}_std"] = float(np.std(mfccs[i]))
        
        return features
    
    def _rule_based_analysis(
        self, 
        audio: np.ndarray, 
        transcript: str,
        acoustic_features: Dict[str, float]
    ) -> EmotionAnalysisResult:
        """基于规则的情绪分析"""
        
        # 1. 基于声学特征的愤怒分数
        acoustic_anger = self._calculate_acoustic_anger(acoustic_features)
        
        # 2. 基于文本的愤怒分数
        text_anger = self._calculate_text_anger(transcript)
        
        # 3. 综合愤怒分数（规则融合）
        anger_score = 0.6 * acoustic_anger + 0.4 * text_anger

        # 4. 若存在多模态模型，融合文本+声学学习分数
        if self.multimodal_model is not None:
            try:
                mm_features = self._build_multimodal_features(transcript, acoustic_features)
                mm_score = self.multimodal_model.predict_bad_probability(mm_features)
                anger_score = 0.2 * anger_score + 0.8 * mm_score
            except Exception as e:
                logger.warning(f"Multimodal inference failed: {e}; fallback to rule score")

        anger_score = max(0.0, min(1.0, anger_score))
        
        # 5. 确定情绪等级
        emotion_level = self._get_emotion_level(anger_score)
        
        # 6. 计算其他维度
        valence = self._calculate_valence(transcript, acoustic_features)
        arousal = self._calculate_arousal(acoustic_features)
        dominance = self._calculate_dominance(acoustic_features, transcript)
        stress = self._calculate_stress(acoustic_features, anger_score)
        impatience = self._calculate_impatience(transcript, acoustic_features)
        
        # 7. 计算置信度
        confidence = self._calculate_confidence(audio, transcript)
        
        return EmotionAnalysisResult(
            anger_score=anger_score,
            emotion_level=emotion_level,
            emotion_value=self._valence_to_emotion_value(valence),
            valence=valence,
            arousal=arousal,
            dominance=dominance,
            stress=stress,
            impatience=impatience,
            acoustic_features=acoustic_features,
            confidence=confidence,
            model_backend="rule",
        )

    def _valence_to_emotion_value(self, valence: float, neutral_margin: float = 0.2) -> int:
        """将连续效价映射为产品需要的 -1 / 0 / 1。"""
        if valence <= -neutral_margin:
            return -1
        if valence >= neutral_margin:
            return 1
        return 0
    
    def _calculate_acoustic_anger(self, features: Dict[str, float]) -> float:
        """基于声学特征计算愤怒分数"""
        score = 0.0
        
        # 高音调增加愤怒可能性
        pitch_mean = features.get("pitch_mean", 150)
        if pitch_mean > 250:
            score += 0.25
        elif pitch_mean > 200:
            score += 0.15
        
        # 高音调方差（声音颤抖）
        pitch_std = features.get("pitch_std", 20)
        if pitch_std > 40:
            score += 0.15
        
        # 高能量（大声说话）
        energy_mean = features.get("energy_mean", 0.1)
        if energy_mean > 0.3:
            score += 0.2
        
        # 高过零率（尖锐声音）
        zcr_mean = features.get("zcr_mean", 0.05)
        if zcr_mean > 0.1:
            score += 0.1
        
        # 快语速
        speaking_rate = features.get("speaking_rate", 2.0)
        if speaking_rate > 5.0:
            score += 0.2
        elif speaking_rate > 4.0:
            score += 0.15
        
        # 少停顿（急促）
        pause_ratio = features.get("pause_ratio", 0.3)
        if pause_ratio < 0.15:
            score += 0.15
        
        # 高频谱质心（尖锐）
        centroid = features.get("spectral_centroid_mean", 2000)
        if centroid > 3000:
            score += 0.1
        
        return min(score, 1.0)

    def _build_multimodal_features(self, transcript: str, acoustic_features: Dict[str, float]) -> Dict[str, float]:
        """拼装多模态模型特征（训练与线上对齐）。"""
        text = transcript.lower().strip()
        anger_hits = sum(1 for w in self.ANGER_KEYWORDS if w in text)
        exclaim = text.count("!") + text.count("！")
        pos_words = ["谢谢", "慢慢", "冷静", "一起", "辛苦", "理解", "好"]
        neg_words = ["生气", "烦", "闭嘴", "受够", "废话", "讨厌", "恨"]
        pos_hits = sum(1 for w in pos_words if w in text)
        neg_hits = sum(1 for w in neg_words if w in text)
        text_len = len(text)

        duration = float(acoustic_features.get("duration", 1.8))
        return {
            "rms": float(acoustic_features.get("energy_mean", 0.0)),
            "peak": float(acoustic_features.get("energy_mean", 0.0) + acoustic_features.get("energy_std", 0.0)),
            "zcr": float(acoustic_features.get("zcr_mean", 0.0)),
            "duration": duration,
            "f0_est": float(acoustic_features.get("pitch_mean", 180.0)),
            "pitch_std": float(acoustic_features.get("pitch_std", 0.0)),
            "pause_ratio": float(acoustic_features.get("pause_ratio", 0.0)),
            "speaking_rate": float(acoustic_features.get("speaking_rate", 0.0)),
            "text_len": float(text_len),
            "exclaim": float(exclaim),
            "anger_hits": float(anger_hits),
            "pos_hits": float(pos_hits),
            "neg_hits": float(neg_hits),
            "speech_rate_proxy": float(text_len / max(duration, 0.1)),
        }
    
    def _calculate_text_anger(self, transcript: str) -> float:
        """基于文本内容计算愤怒分数。

        规则引擎 + 文本模型融合：
        - 若存在文本模型，使用 70% 模型分 + 30% 规则分
        - 否则退化为纯规则
        """
        if not transcript:
            return 0.0

        text = transcript.lower()
        rule_score = 0.0

        # 检查愤怒关键词
        for keyword in self.ANGER_KEYWORDS:
            if keyword in text:
                rule_score += 0.2

        # 检查感叹号数量
        exclamation_count = text.count("！") + text.count("!")
        rule_score += min(exclamation_count * 0.1, 0.3)

        # 检查大写字母比例（英文 shouting）
        if any(c.isalpha() for c in text):
            upper_ratio = sum(1 for c in text if c.isupper()) / sum(1 for c in text if c.isalpha())
            if upper_ratio > 0.5:
                rule_score += 0.15

        # 检查重复字符（如"啊啊啊"）
        import re

        repeats = len(re.findall(r"(.)\1{2,}", text))
        rule_score += min(repeats * 0.1, 0.2)
        rule_score = min(rule_score, 1.0)

        if self.text_model is not None:
            try:
                model_score = self.text_model.predict(transcript).bad_probability
                return min(max(0.7 * model_score + 0.3 * rule_score, 0.0), 1.0)
            except Exception as e:
                logger.warning(f"Text model inference failed: {e}; fallback to rule score")

        return rule_score
    
    def _calculate_valence(self, transcript: str, features: Dict[str, float]) -> float:
        """计算情感效价 (-1 到 1)"""
        # 基于文本情感词典的简单实现
        positive_words = ["好", "棒", "喜欢", "爱", "开心", "谢谢", "不错", "很好"]
        negative_words = ["坏", "差", "讨厌", "恨", "难过", "生气", "不好", "糟糕"]
        
        text = transcript.lower()
        pos_count = sum(1 for w in positive_words if w in text)
        neg_count = sum(1 for w in negative_words if w in text)
        
        if pos_count == 0 and neg_count == 0:
            # 基于声学特征估计
            energy = features.get("energy_mean", 0.1)
            return 0.1 if energy < 0.2 else -0.1
        
        return (pos_count - neg_count) / max(pos_count + neg_count, 1)
    
    def _calculate_arousal(self, features: Dict[str, float]) -> float:
        """计算唤醒度 (0 到 1)"""
        score = 0.0
        
        # 能量水平
        energy = features.get("energy_mean", 0.1)
        score += energy * 0.3
        
        # 语速
        rate = features.get("speaking_rate", 2.0)
        score += min(rate / 6.0, 1.0) * 0.3
        
        # 音调变化
        pitch_std = features.get("pitch_std", 20)
        score += min(pitch_std / 100, 1.0) * 0.2
        
        # 过零率
        zcr = features.get("zcr_mean", 0.05)
        score += min(zcr / 0.2, 1.0) * 0.2
        
        return min(score, 1.0)
    
    def _calculate_dominance(self, features: Dict[str, float], transcript: str) -> float:
        """计算支配度 (0 到 1)"""
        score = 0.5  # 中性起点
        
        # 音量越大越有支配感
        energy = features.get("energy_mean", 0.1)
        score += (energy - 0.1) * 0.3
        
        # 低音调更有支配感
        pitch = features.get("pitch_mean", 150)
        if pitch < 120:
            score += 0.2
        elif pitch > 200:
            score -= 0.1
        
        # 命令式语句
        command_words = ["必须", "应该", "给我", "听我的", "按我说的"]
        for word in command_words:
            if word in transcript:
                score += 0.1
        
        return max(0.0, min(1.0, score))
    
    def _calculate_stress(self, features: Dict[str, float], anger_score: float) -> float:
        """计算压力指数"""
        score = anger_score * 0.4  # 愤怒与压力相关
        
        # 声音颤抖（高方差）
        pitch_std = features.get("pitch_std", 20)
        score += min(pitch_std / 80, 1.0) * 0.2
        
        # 不自然的停顿模式
        pause_ratio = features.get("pause_ratio", 0.3)
        if pause_ratio > 0.4 or pause_ratio < 0.1:
            score += 0.2
        
        # 语速不稳定
        rate = features.get("speaking_rate", 2.0)
        if rate > 5.0 or rate < 1.5:
            score += 0.2
        
        return min(score, 1.0)
    
    def _calculate_impatience(self, transcript: str, features: Dict[str, float]) -> float:
        """计算不耐烦指数"""
        score = 0.0
        
        # 关键词匹配
        for keyword in self.IMPATIENCE_KEYWORDS:
            if keyword in transcript:
                score += 0.25
        
        # 语速快
        rate = features.get("speaking_rate", 2.0)
        if rate > 4.5:
            score += 0.2
        
        # 停顿少（急促）
        pause_ratio = features.get("pause_ratio", 0.3)
        if pause_ratio < 0.1:
            score += 0.2
        
        # 打断对方（基于音频中的重叠检测，这里简化处理）
        energy_std = features.get("energy_std", 0.05)
        if energy_std > 0.1:
            score += 0.15
        
        return min(score, 1.0)
    
    def _get_emotion_level(self, anger_score: float) -> str:
        """根据愤怒分数确定情绪等级"""
        for min_val, max_val, level in self.EMOTION_LEVELS:
            if min_val <= anger_score < max_val:
                return level
        return "extreme"
    
    def _calculate_confidence(self, audio: np.ndarray, transcript: str) -> float:
        """计算分析置信度"""
        confidence = 0.5
        
        # 音频质量
        snr = self._estimate_snr(audio)
        if snr > 20:
            confidence += 0.2
        elif snr > 10:
            confidence += 0.1
        
        # 音频长度
        duration = len(audio) / self.sample_rate
        if duration > 2.0:
            confidence += 0.15
        elif duration > 1.0:
            confidence += 0.1
        
        # 文本质量
        if transcript and len(transcript) > 5:
            confidence += 0.15
        
        return min(confidence, 1.0)
    
    def _estimate_snr(self, audio: np.ndarray) -> float:
        """估计信噪比"""
        # 简化实现：使用信号能量与静音段能量的比值
        frame_length = int(0.025 * self.sample_rate)  # 25ms
        hop_length = int(0.01 * self.sample_rate)     # 10ms
        
        frames = librosa.util.frame(audio, frame_length=frame_length, hop_length=hop_length)
        frame_energies = np.sum(frames ** 2, axis=0)
        
        # 假设最低20%的帧是静音
        sorted_energies = np.sort(frame_energies)
        noise_energy = np.mean(sorted_energies[:len(sorted_energies)//5])
        signal_energy = np.mean(sorted_energies[len(sorted_energies)//5:])
        
        if noise_energy == 0:
            return 40.0
        
        snr = 10 * np.log10(signal_energy / noise_energy)
        return float(snr)
    
    def analyze(
        self, 
        audio: np.ndarray, 
        transcript: str = "",
        sr: int = 16000
    ) -> EmotionAnalysisResult:
        """
        分析语音情绪
        
        Args:
            audio: 音频数据，numpy数组
            transcript: 转录文本（可选）
            sr: 采样率
            
        Returns:
            EmotionAnalysisResult: 情绪分析结果
        """
        # 重采样到标准采样率
        if sr != self.sample_rate:
            audio = librosa.resample(audio, orig_sr=sr, target_sr=self.sample_rate)
        
        # 提取声学特征
        acoustic_features = self._extract_acoustic_features(audio, self.sample_rate)
        
        # Use the configured model directly. If it cannot load, avoid silently
        # returning heuristic rule scores as if they were model predictions.
        if self.backend == "emotion2vec":
            if self._ensure_emotion2vec_model():
                return self._emotion2vec_based_analysis(audio, transcript, acoustic_features)
            return self._model_unavailable_analysis("emotion2vec", transcript, acoustic_features)
        if self.backend == "sensevoice":
            if self._ensure_sensevoice_model():
                return self._sensevoice_based_analysis(audio, transcript, acoustic_features)
            return self._model_unavailable_analysis("sensevoice", transcript, acoustic_features)
        if self.backend == "caire":
            if self._ensure_caire_model():
                return self._caire_based_analysis(audio, transcript, acoustic_features)
            return self._model_unavailable_analysis("caire", transcript, acoustic_features)
        if self.use_ml_model and self.model:
            return self._ml_based_analysis(audio, transcript, acoustic_features)
        else:
            return self._rule_based_analysis(audio, transcript, acoustic_features)

    def _model_unavailable_analysis(
        self,
        backend: str,
        transcript: str,
        acoustic_features: Dict[str, float],
    ) -> EmotionAnalysisResult:
        return EmotionAnalysisResult(
            anger_score=0.0,
            emotion_level="calm",
            emotion_value=0,
            valence=0.0,
            arousal=0.0,
            dominance=0.5,
            stress=0.0,
            impatience=0.0,
            acoustic_features=acoustic_features,
            confidence=0.0,
            model_backend=f"{backend}_unavailable",
            raw_emotions={"neutral": 1.0},
            transcript=transcript,
        )

    def _emotion2vec_based_analysis(
        self,
        audio: np.ndarray,
        transcript: str,
        acoustic_features: Dict[str, float],
    ) -> EmotionAnalysisResult:
        """Use FunASR emotion2vec utterance emotion scores and map them to -1/0/1."""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
            temp_path = temp_file.name

        try:
            sf.write(temp_path, audio.astype(np.float32), self.sample_rate)
            result = self._emotion2vec_model.generate(
                input=temp_path,
                granularity="utterance",
                extract_embedding=False,
            )
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass

        raw_emotions = self._extract_emotion2vec_scores(result)
        if not raw_emotions:
            logger.warning("emotion2vec returned no usable emotion scores: %s", result)
            return self._rule_based_analysis(audio, transcript, acoustic_features)

        raw_emotions.setdefault("angry", 0.0)
        raw_emotions.setdefault("disgusted", 0.0)
        raw_emotions.setdefault("fearful", 0.0)
        raw_emotions.setdefault("happy", 0.0)
        raw_emotions.setdefault("neutral", 0.0)
        raw_emotions.setdefault("sad", 0.0)
        raw_emotions.setdefault("other", 0.0)
        raw_emotions.setdefault("unknown", 0.0)

        positive_score = raw_emotions["happy"]
        negative_score = max(
            raw_emotions["angry"],
            raw_emotions["sad"],
            raw_emotions["fearful"],
            raw_emotions["disgusted"],
        )
        neutral_score = max(raw_emotions["neutral"], raw_emotions["other"], raw_emotions["unknown"] * 0.8)
        valence = float(np.clip(positive_score - negative_score, -1.0, 1.0))
        top_label = max(raw_emotions, key=raw_emotions.get)
        top_score = raw_emotions[top_label]

        if neutral_score >= max(positive_score, negative_score) * 0.9 or abs(valence) < 0.12:
            emotion_value = 0
        else:
            emotion_value = 1 if valence > 0 else -1

        anger_score = max(
            raw_emotions["angry"],
            raw_emotions["disgusted"] * 0.75,
            raw_emotions["fearful"] * 0.55,
            raw_emotions["sad"] * 0.35,
        )
        arousal = max(
            raw_emotions["angry"],
            raw_emotions["happy"] * 0.7,
            raw_emotions["fearful"],
            raw_emotions["disgusted"] * 0.7,
        )
        stress = max(
            raw_emotions["angry"],
            raw_emotions["fearful"],
            raw_emotions["sad"] * 0.75,
            raw_emotions["disgusted"] * 0.75,
        )
        if emotion_value == 1:
            stress = min(stress, 0.35)
            anger_score = min(anger_score, 0.35)

        confidence = float(np.clip(top_score, 0.0, 1.0))
        emotion_intensity = float(np.clip(max(anger_score, stress, arousal * 0.5), 0.0, 1.0))

        return EmotionAnalysisResult(
            anger_score=float(np.clip(anger_score, 0.0, 1.0)),
            emotion_level=self._get_emotion_level(emotion_intensity),
            emotion_value=emotion_value,
            valence=valence,
            arousal=float(np.clip(arousal, 0.0, 1.0)),
            dominance=float(np.clip(
                0.5 + raw_emotions["angry"] * 0.25 + positive_score * 0.12 - raw_emotions["sad"] * 0.2,
                0.0,
                1.0,
            )),
            stress=float(np.clip(stress, 0.0, 1.0)),
            impatience=float(np.clip(max(raw_emotions["angry"], raw_emotions["disgusted"] * 0.7), 0.0, 1.0)),
            acoustic_features=acoustic_features,
            confidence=confidence,
            model_backend="emotion2vec",
            raw_emotions=raw_emotions,
            transcript=transcript,
        )

    def _extract_emotion2vec_scores(self, result: Any) -> Dict[str, float]:
        """Normalize FunASR emotion2vec output into stable English labels."""
        item = result[0] if isinstance(result, list) and result else result
        if not isinstance(item, dict):
            return {}

        labels = item.get("labels") or item.get("label")
        scores = item.get("scores") or item.get("score")
        if isinstance(labels, str):
            labels = [labels]
        if isinstance(scores, (int, float)):
            scores = [scores]

        if not labels or not scores:
            output = item.get("output")
            if isinstance(output, dict):
                labels = output.get("labels") or output.get("label")
                scores = output.get("scores") or output.get("score")

        raw_emotions: Dict[str, float] = {}
        if isinstance(labels, list) and isinstance(scores, list):
            for label, score in zip(labels, scores):
                normalized = self._normalize_emotion2vec_label(str(label))
                if normalized:
                    raw_emotions[normalized] = max(raw_emotions.get(normalized, 0.0), float(score))
        return raw_emotions

    def _normalize_emotion2vec_label(self, label: str) -> Optional[str]:
        text = label.strip().lower()
        if "angry" in text or "anger" in text or "生气" in text or "愤怒" in text:
            return "angry"
        if "disgust" in text or "厌恶" in text:
            return "disgusted"
        if "fear" in text or "恐惧" in text or "害怕" in text:
            return "fearful"
        if "happy" in text or "happiness" in text or "开心" in text or "高兴" in text:
            return "happy"
        if "neutral" in text or "中立" in text or "平静" in text:
            return "neutral"
        if "sad" in text or "sadness" in text or "难过" in text or "悲伤" in text:
            return "sad"
        if "surprise" in text or "惊讶" in text:
            return "surprise"
        if "other" in text or "其他" in text:
            return "other"
        if "unk" in text or "unknown" in text:
            return "unknown"
        return None

    def _sensevoice_based_analysis(
        self,
        audio: np.ndarray,
        transcript: str,
        acoustic_features: Dict[str, float],
    ) -> EmotionAnalysisResult:
        """Use SenseVoiceSmall emotion tags and map them to -1/0/1."""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
            temp_path = temp_file.name

        try:
            sf.write(temp_path, audio.astype(np.float32), self.sample_rate)
            result = self._sensevoice_model.generate(
                input=temp_path,
                cache={},
                language="auto",
                use_itn=True,
                batch_size_s=30,
            )
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass

        raw_text = ""
        if isinstance(result, list) and result:
            item = result[0]
            raw_text = str(item.get("text", "")) if isinstance(item, dict) else str(item)
        else:
            raw_text = str(result)

        emotion_tag = self._extract_sensevoice_emotion(raw_text)
        effective_transcript = transcript.strip() or self._extract_sensevoice_transcript(raw_text)
        if emotion_tag == "sad" and self._is_benign_neutral_transcript(effective_transcript):
            logger.info(
                "SenseVoice SAD overridden to NEUTRAL for benign short transcript: %s",
                effective_transcript,
            )
            emotion_tag = "neutral"
        raw_emotions = self._sensevoice_raw_scores(emotion_tag)
        anger_score = raw_emotions.get("angry", 0.0)
        sad_score = raw_emotions.get("sad", 0.0)
        positive_score = raw_emotions.get("happy", 0.0)
        negative_score = max(sad_score, anger_score)
        valence = float(np.clip(positive_score - negative_score, -1.0, 1.0))

        if emotion_tag == "happy":
            emotion_value = 1
        elif emotion_tag in {"angry", "sad"}:
            emotion_value = -1
        else:
            emotion_value = 0

        arousal = 0.75 if emotion_tag == "angry" else 0.55 if emotion_tag == "happy" else 0.35
        stress = 0.8 if emotion_tag == "angry" else 0.55 if emotion_tag == "sad" else 0.15
        emotion_intensity = float(np.clip(max(anger_score, stress * 0.7), 0.0, 1.0))

        return EmotionAnalysisResult(
            anger_score=float(np.clip(anger_score, 0.0, 1.0)),
            emotion_level=self._get_emotion_level(emotion_intensity),
            emotion_value=emotion_value,
            valence=valence,
            arousal=float(np.clip(arousal, 0.0, 1.0)),
            dominance=float(np.clip(0.5 + anger_score * 0.25 - sad_score * 0.2, 0.0, 1.0)),
            stress=float(np.clip(stress, 0.0, 1.0)),
            impatience=float(np.clip(anger_score * 0.75, 0.0, 1.0)),
            acoustic_features=acoustic_features,
            confidence=float(np.clip(max(raw_emotions.values()), 0.0, 1.0)),
            model_backend="sensevoice",
            raw_emotions=raw_emotions,
            transcript=effective_transcript,
        )

    def _extract_sensevoice_emotion(self, raw_text: str) -> str:
        text = raw_text.upper()
        if "<|HAPPY|>" in text or "|HAPPY|" in text or "HAPPY" in text:
            return "happy"
        if "<|ANGRY|>" in text or "|ANGRY|" in text or "ANGRY" in text:
            return "angry"
        if "<|SAD|>" in text or "|SAD|" in text or "SAD" in text:
            return "sad"
        return "neutral"

    def _extract_sensevoice_transcript(self, raw_text: str) -> str:
        import re

        return re.sub(r"<\|[^|]+\|>", "", raw_text).strip()

    def _is_benign_neutral_transcript(self, transcript: str) -> bool:
        import re

        text = re.sub(r"[\s，。！？!?,.;；、~～…]+", "", transcript.strip().lower())
        if not text:
            return False

        negative_markers = [
            "生气", "难过", "伤心", "哭", "烦", "讨厌", "糟", "差", "不好", "别",
            "滚", "闭嘴", "作业", "没写", "为什么", "怎么又", "不行", "不要",
        ]
        if any(marker in text for marker in negative_markers):
            return False

        benign_markers = [
            "你好", "您好", "早上好", "中午好", "下午好", "晚上好", "哈喽", "hello",
            "hi", "谢谢", "多谢", "好的", "好呀", "可以", "行", "嗯", "哦", "收到",
            "知道了", "没问题", "再见", "拜拜",
        ]
        if any(marker in text for marker in benign_markers) and len(text) <= 16:
            return True

        return False

    def _predict_tri_class(
        self,
        transcript: str,
        acoustic_features: Dict[str, float],
    ) -> Optional[Dict[int, float]]:
        if self.tri_class_model is None:
            return None
        try:
            features = self._build_multimodal_features(transcript, acoustic_features)
            return self.tri_class_model.predict_probabilities(features)
        except Exception as exc:
            logger.warning("Tri-class emotion calibration failed: %s", exc)
            return None

    def _sensevoice_raw_scores(self, emotion_tag: str) -> Dict[str, float]:
        scores = {
            "happy": 0.02,
            "sad": 0.02,
            "angry": 0.02,
            "neutral": 0.02,
        }
        scores[emotion_tag if emotion_tag in scores else "neutral"] = 0.9
        return scores

    def _caire_based_analysis(
        self,
        audio: np.ndarray,
        transcript: str,
        acoustic_features: Dict[str, float],
    ) -> EmotionAnalysisResult:
        """使用 CAiRE 中英文语音情绪识别模型，并聚合成 -1/0/1。"""
        inputs = self._caire_feature_extractor(
            audio.astype(np.float32),
            sampling_rate=self.sample_rate,
            return_tensors="pt",
            padding=True,
        )
        inputs = {key: value.to(self.device) for key, value in inputs.items()}

        with torch.no_grad():
            logits = self._caire_model(**inputs).logits[0]
            probs = torch.sigmoid(logits).detach().cpu().numpy()

        raw_emotions = {
            label: float(probs[index]) for index, label in enumerate(self.CAIRE_LABELS)
        }

        positive_score = max(raw_emotions[label] for label in self.POSITIVE_LABELS)
        negative_score = max(raw_emotions[label] for label in self.NEGATIVE_LABELS)
        neutral_score = raw_emotions["neutral"]
        valence = float(np.clip(positive_score - negative_score, -1.0, 1.0))

        if neutral_score >= max(positive_score, negative_score) * 0.9 or abs(valence) < 0.15:
            emotion_value = 0
        else:
            emotion_value = 1 if valence > 0 else -1

        anger_score = max(
            raw_emotions["angry"],
            raw_emotions["frustrated"] * 0.85,
            raw_emotions["negative"] * 0.7,
            raw_emotions["disgust"] * 0.65,
            raw_emotions["fear"] * 0.5,
            raw_emotions["sadness"] * 0.4,
        )
        arousal = max(
            raw_emotions["angry"],
            raw_emotions["fear"],
            raw_emotions["surprise"],
            raw_emotions["excitement"],
            raw_emotions["frustrated"],
        )
        dominance = float(np.clip(
            0.45 + raw_emotions["angry"] * 0.35 + raw_emotions["positive"] * 0.2
            - raw_emotions["sadness"] * 0.25,
            0.0,
            1.0,
        ))
        stress = max(raw_emotions["angry"], raw_emotions["fear"], raw_emotions["frustrated"], raw_emotions["negative"])
        impatience = max(raw_emotions["frustrated"], raw_emotions["angry"] * 0.75)
        confidence = max(raw_emotions.values())

        return EmotionAnalysisResult(
            anger_score=float(np.clip(anger_score, 0.0, 1.0)),
            emotion_level=self._get_emotion_level(float(np.clip(anger_score, 0.0, 1.0))),
            emotion_value=emotion_value,
            valence=valence,
            arousal=float(np.clip(arousal, 0.0, 1.0)),
            dominance=dominance,
            stress=float(np.clip(stress, 0.0, 1.0)),
            impatience=float(np.clip(impatience, 0.0, 1.0)),
            acoustic_features=acoustic_features,
            confidence=float(np.clip(confidence, 0.0, 1.0)),
            model_backend="caire",
            raw_emotions=raw_emotions,
        )
    
    def _ml_based_analysis(
        self, 
        audio: np.ndarray, 
        transcript: str,
        acoustic_features: Dict[str, float]
    ) -> EmotionAnalysisResult:
        """基于ML模型的情绪分析"""
        # 提取梅尔频谱
        mel_spec = self._extract_mel_spectrogram(audio)
        
        # 调整尺寸为模型输入
        target_length = 256
        if mel_spec.shape[1] < target_length:
            mel_spec = np.pad(mel_spec, ((0, 0), (0, target_length - mel_spec.shape[1])))
        else:
            mel_spec = mel_spec[:, :target_length]
        
        # 归一化
        mel_spec = (mel_spec - mel_spec.mean()) / (mel_spec.std() + 1e-8)
        
        # 转换为tensor
        input_tensor = torch.FloatTensor(mel_spec).unsqueeze(0).unsqueeze(0).to(self.device)
        
        # 推理
        with torch.no_grad():
            output = self.model(input_tensor)
        
        # 解析输出
        probs = output.cpu().numpy()[0]
        
        # 映射到情绪维度
        anger_score = float(probs[0])
        valence = float(probs[1]) * 2 - 1  # 映射到 -1 到 1
        arousal = float(probs[2])
        dominance = float(probs[3])
        stress = float(probs[4])
        
        # 计算不耐烦（基于文本）
        impatience = self._calculate_impatience(transcript, acoustic_features)
        
        emotion_level = self._get_emotion_level(anger_score)
        confidence = self._calculate_confidence(audio, transcript)
        
        return EmotionAnalysisResult(
            anger_score=anger_score,
            emotion_level=emotion_level,
            emotion_value=self._valence_to_emotion_value(valence),
            valence=valence,
            arousal=arousal,
            dominance=dominance,
            stress=stress,
            impatience=impatience,
            acoustic_features=acoustic_features,
            confidence=confidence,
            model_backend="local_cnn",
        )
    
    def analyze_batch(
        self, 
        audio_segments: list[np.ndarray], 
        transcripts: list[str],
        sr: int = 16000
    ) -> list[EmotionAnalysisResult]:
        """批量分析多个音频片段"""
        results = []
        for audio, transcript in zip(audio_segments, transcripts):
            result = self.analyze(audio, transcript, sr)
            results.append(result)
        return results
