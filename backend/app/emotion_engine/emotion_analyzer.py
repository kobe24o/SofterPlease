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
from dataclasses import dataclass
import librosa
import torch
import torch.nn as nn

from .text_emotion_model import TextEmotionModel
from .multimodal_emotion_model import MultimodalEmotionModel

# 配置日志
logger = logging.getLogger(__name__)


@dataclass
class EmotionAnalysisResult:
    """情绪分析结果"""
    anger_score: float  # 0-1, 愤怒程度
    emotion_level: str  # calm, mild, moderate, high, extreme
    
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
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "anger_score": round(self.anger_score, 4),
            "emotion_level": self.emotion_level,
            "emotion_dimensions": {
                "valence": round(self.valence, 4),
                "arousal": round(self.arousal, 4),
                "dominance": round(self.dominance, 4),
                "stress": round(self.stress, 4),
                "impatience": round(self.impatience, 4),
            },
            "acoustic_features": self.acoustic_features,
            "confidence": round(self.confidence, 4),
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
    
    def __init__(self, model_path: Optional[str] = None, device: str = "cpu"):
        self.device = torch.device(device)
        self.sample_rate = 16000
        self.n_mels = 128
        self.hop_length = 512
        self.n_fft = 2048
        
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

        # 优先使用传入的路径，其次从环境变量读取
        if model_path is None:
            model_path = os.getenv('EMOTION_MODEL_PATH', 'models/emotion_cnn.pth')
        
        if model_path and os.path.exists(model_path):
            try:
                self.model = EmotionCNN().to(self.device)
                self.model.load_state_dict(torch.load(model_path, map_location=self.device))
                self.model.eval()
                self.use_ml_model = True
                logger.info(f"Successfully loaded ML model from {model_path}")
            except Exception as e:
                logger.warning(f"Failed to load ML model from {model_path}: {e}")
                logger.info("Falling back to rule-based engine")
        else:
            if model_path:
                logger.warning(f"Model weights not found at {model_path}, using rule-based engine")
            else:
                logger.info("No model path provided, using rule-based engine")
    
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
            valence=valence,
            arousal=arousal,
            dominance=dominance,
            stress=stress,
            impatience=impatience,
            acoustic_features=acoustic_features,
            confidence=confidence,
        )
    
    def _calculate_acoustic_anger(self, features: Dict[str, float]) -> float:
        """基于声学特征计算愤怒分数"""
        score = 0.0
        
        # 高音调增加愤怒可能性
        pitch_mean = features.get("pitch_mean", 150)
        if pitch_mean > 200:
            score += 0.15
        elif pitch_mean > 250:
            score += 0.25
        
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
        if speaking_rate > 4.0:
            score += 0.15
        elif speaking_rate > 5.0:
            score += 0.2
        
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

        duration = 1.8  # 在线推理中没有完整时长特征时给定稳定默认
        return {
            "rms": float(acoustic_features.get("energy_mean", 0.0)),
            "peak": float(acoustic_features.get("energy_mean", 0.0) + acoustic_features.get("energy_std", 0.0)),
            "zcr": float(acoustic_features.get("zcr_mean", 0.0)),
            "duration": duration,
            "f0_est": float(acoustic_features.get("pitch_mean", 180.0)),
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
        
        # 使用ML模型或规则引擎
        if self.use_ml_model and self.model:
            return self._ml_based_analysis(audio, transcript, acoustic_features)
        else:
            return self._rule_based_analysis(audio, transcript, acoustic_features)
    
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
            valence=valence,
            arousal=arousal,
            dominance=dominance,
            stress=stress,
            impatience=impatience,
            acoustic_features=acoustic_features,
            confidence=confidence,
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
