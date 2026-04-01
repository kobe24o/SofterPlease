"""
声纹识别模块 - 识别说话人身份

支持功能：
- 声纹注册（创建声纹档案）
- 声纹识别（识别说话人）
- 声纹验证（验证身份）
"""

from __future__ import annotations

import numpy as np
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
import librosa
import torch
import torch.nn as nn


@dataclass
class VoiceRecognitionResult:
    """声纹识别结果"""
    speaker_id: str
    confidence: float
    is_known: bool
    top_matches: List[Tuple[str, float]]  # [(speaker_id, score), ...]
    
    def to_dict(self) -> Dict:
        return {
            "speaker_id": self.speaker_id,
            "confidence": round(self.confidence, 4),
            "is_known": self.is_known,
            "top_matches": [(sid, round(score, 4)) for sid, score in self.top_matches],
        }


class SpeakerEmbeddingModel(nn.Module):
    """说话人嵌入模型 (基于x-vector架构的简化版)"""
    
    def __init__(self, embedding_dim: int = 256):
        super().__init__()
        
        # TDNN (Time-Delay Neural Network) 层
        self.tdnn = nn.Sequential(
            # Layer 1
            nn.Conv1d(40, 512, kernel_size=5, dilation=1),
            nn.ReLU(),
            nn.BatchNorm1d(512),
            
            # Layer 2
            nn.Conv1d(512, 512, kernel_size=3, dilation=2),
            nn.ReLU(),
            nn.BatchNorm1d(512),
            
            # Layer 3
            nn.Conv1d(512, 512, kernel_size=3, dilation=3),
            nn.ReLU(),
            nn.BatchNorm1d(512),
            
            # Layer 4
            nn.Conv1d(512, 512, kernel_size=1, dilation=1),
            nn.ReLU(),
            nn.BatchNorm1d(512),
            
            # Layer 5
            nn.Conv1d(512, 1500, kernel_size=1, dilation=1),
            nn.ReLU(),
            nn.BatchNorm1d(1500),
        )
        
        # 统计池化层
        self.segment = nn.Sequential(
            nn.Linear(3000, embedding_dim),
            nn.ReLU(),
            nn.BatchNorm1d(embedding_dim),
        )
    
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (batch, n_mels, time)
        x = self.tdnn(x)
        
        # 统计池化
        mean = torch.mean(x, dim=2)
        std = torch.std(x, dim=2)
        stat_pooling = torch.cat([mean, std], dim=1)
        
        # 分段层
        embedding = self.segment(stat_pooling)
        
        # L2归一化
        embedding = torch.nn.functional.normalize(embedding, p=2, dim=1)
        
        return embedding


class VoiceRecognizer:
    """
    声纹识别器
    
    管理声纹档案，识别说话人身份
    """
    
    # 识别阈值
    RECOGNITION_THRESHOLD = 0.65  # 低于此值视为未知说话人
    VERIFICATION_THRESHOLD = 0.75  # 验证阈值
    
    def __init__(
        self, 
        model_path: Optional[str] = None,
        embedding_dim: int = 256,
        device: str = "cpu"
    ):
        self.device = torch.device(device)
        self.embedding_dim = embedding_dim
        self.sample_rate = 16000
        
        # 声纹档案库 {speaker_id: embedding}
        self.voice_profiles: Dict[str, np.ndarray] = {}
        
        # 初始化模型
        self.model = None
        self.use_ml_model = False
        
        if model_path:
            try:
                self.model = SpeakerEmbeddingModel(embedding_dim).to(self.device)
                self.model.load_state_dict(torch.load(model_path, map_location=self.device))
                self.model.eval()
                self.use_ml_model = True
            except Exception as e:
                print(f"Failed to load speaker model: {e}, using rule-based engine")
    
    def _extract_mfcc(self, audio: np.ndarray, sr: int) -> np.ndarray:
        """提取MFCC特征"""
        mfcc = librosa.feature.mfcc(
            y=audio,
            sr=sr,
            n_mfcc=40,
            n_fft=512,
            hop_length=160,
        )
        return mfcc
    
    def _extract_embedding_rule_based(self, audio: np.ndarray, sr: int) -> np.ndarray:
        """基于规则的声纹特征提取"""
        # 提取多种声学特征并组合
        features = []
        
        # MFCC
        mfcc = self._extract_mfcc(audio, sr)
        mfcc_mean = np.mean(mfcc, axis=1)
        mfcc_std = np.std(mfcc, axis=1)
        features.extend(mfcc_mean)
        features.extend(mfcc_std)
        
        # 基频统计
        pitches, magnitudes = librosa.piptrack(y=audio, sr=sr)
        pitch_values = pitches[magnitudes > np.median(magnitudes)]
        if len(pitch_values) > 0:
            features.extend([
                np.mean(pitch_values),
                np.std(pitch_values),
                np.max(pitch_values),
                np.min(pitch_values),
            ])
        else:
            features.extend([0, 0, 0, 0])
        
        # 频谱特征
        spectral_centroids = librosa.feature.spectral_centroid(y=audio, sr=sr)[0]
        spectral_rolloff = librosa.feature.spectral_rolloff(y=audio, sr=sr)[0]
        spectral_bandwidth = librosa.feature.spectral_bandwidth(y=audio, sr=sr)[0]
        
        features.extend([
            np.mean(spectral_centroids),
            np.std(spectral_centroids),
            np.mean(spectral_rolloff),
            np.std(spectral_rolloff),
            np.mean(spectral_bandwidth),
            np.std(spectral_bandwidth),
        ])
        
        # 过零率
        zcr = librosa.feature.zero_crossing_rate(y=audio)[0]
        features.extend([np.mean(zcr), np.std(zcr)])
        
        # 能量
        rms = librosa.feature.rms(y=audio)[0]
        features.extend([np.mean(rms), np.std(rms)])
        
        # 确保固定维度
        embedding = np.array(features, dtype=np.float32)
        
        # 如果维度不足，补零
        if len(embedding) < self.embedding_dim:
            embedding = np.pad(embedding, (0, self.embedding_dim - len(embedding)))
        else:
            embedding = embedding[:self.embedding_dim]
        
        # L2归一化
        embedding = embedding / (np.linalg.norm(embedding) + 1e-8)
        
        return embedding
    
    def _extract_embedding_ml(self, audio: np.ndarray, sr: int) -> np.ndarray:
        """使用ML模型提取声纹嵌入"""
        # 提取MFCC
        mfcc = self._extract_mfcc(audio, sr)
        
        # 归一化
        mfcc = (mfcc - mfcc.mean()) / (mfcc.std() + 1e-8)
        
        # 转换为tensor
        input_tensor = torch.FloatTensor(mfcc).unsqueeze(0).to(self.device)
        
        # 推理
        with torch.no_grad():
            embedding = self.model(input_tensor)
        
        return embedding.cpu().numpy()[0]
    
    def extract_embedding(self, audio: np.ndarray, sr: int = 16000) -> np.ndarray:
        """提取声纹嵌入向量"""
        # 重采样
        if sr != self.sample_rate:
            audio = librosa.resample(audio, orig_sr=sr, target_sr=self.sample_rate)
        
        # 预处理
        audio = self._preprocess_audio(audio)
        
        if self.use_ml_model and self.model:
            return self._extract_embedding_ml(audio, self.sample_rate)
        else:
            return self._extract_embedding_rule_based(audio, self.sample_rate)
    
    def _preprocess_audio(self, audio: np.ndarray) -> np.ndarray:
        """音频预处理"""
        # 去除静音段
        intervals = librosa.effects.split(audio, top_db=20)
        if len(intervals) > 0:
            audio_parts = []
            for start, end in intervals:
                audio_parts.append(audio[start:end])
            audio = np.concatenate(audio_parts)
        
        # 归一化
        audio = audio / (np.max(np.abs(audio)) + 1e-8)
        
        return audio
    
    def _cosine_similarity(self, a: np.ndarray, b: np.ndarray) -> float:
        """计算余弦相似度"""
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-8))
    
    def register_voice(
        self, 
        speaker_id: str, 
        audio_samples: List[np.ndarray],
        sr: int = 16000
    ) -> Dict:
        """
        注册声纹
        
        Args:
            speaker_id: 说话人ID
            audio_samples: 多个音频样本
            sr: 采样率
            
        Returns:
            注册结果
        """
        if len(audio_samples) == 0:
            raise ValueError("At least one audio sample is required")
        
        # 提取所有样本的嵌入
        embeddings = []
        total_duration = 0
        
        for audio in audio_samples:
            embedding = self.extract_embedding(audio, sr)
            embeddings.append(embedding)
            total_duration += len(audio) / sr
        
        # 计算平均嵌入
        avg_embedding = np.mean(embeddings, axis=0)
        avg_embedding = avg_embedding / (np.linalg.norm(avg_embedding) + 1e-8)
        
        # 计算样本间的一致性（方差）
        if len(embeddings) > 1:
            similarities = []
            for i in range(len(embeddings)):
                for j in range(i + 1, len(embeddings)):
                    sim = self._cosine_similarity(embeddings[i], embeddings[j])
                    similarities.append(sim)
            consistency = float(np.mean(similarities))
        else:
            consistency = 1.0
        
        # 存储声纹
        self.voice_profiles[speaker_id] = avg_embedding
        
        return {
            "speaker_id": speaker_id,
            "sample_count": len(audio_samples),
            "total_duration_seconds": round(total_duration, 2),
            "consistency_score": round(consistency, 4),
            "status": "registered",
        }
    
    def recognize(
        self, 
        audio: np.ndarray, 
        sr: int = 16000,
        top_k: int = 3
    ) -> VoiceRecognitionResult:
        """
        识别说话人
        
        Args:
            audio: 音频数据
            sr: 采样率
            top_k: 返回前k个匹配结果
            
        Returns:
            VoiceRecognitionResult
        """
        if len(self.voice_profiles) == 0:
            return VoiceRecognitionResult(
                speaker_id="unknown",
                confidence=0.0,
                is_known=False,
                top_matches=[],
            )
        
        # 提取查询音频的嵌入
        query_embedding = self.extract_embedding(audio, sr)
        
        # 计算与所有档案的相似度
        similarities = []
        for speaker_id, profile_embedding in self.voice_profiles.items():
            sim = self._cosine_similarity(query_embedding, profile_embedding)
            similarities.append((speaker_id, sim))
        
        # 排序
        similarities.sort(key=lambda x: x[1], reverse=True)
        
        # 获取最佳匹配
        best_match = similarities[0]
        speaker_id = best_match[0]
        confidence = best_match[1]
        
        # 判断是否已知
        is_known = confidence >= self.RECOGNITION_THRESHOLD
        
        if not is_known:
            speaker_id = "unknown"
        
        return VoiceRecognitionResult(
            speaker_id=speaker_id,
            confidence=confidence,
            is_known=is_known,
            top_matches=similarities[:top_k],
        )
    
    def verify(
        self, 
        speaker_id: str, 
        audio: np.ndarray, 
        sr: int = 16000
    ) -> Dict:
        """
        验证说话人身份
        
        Args:
            speaker_id: 声称的说话人ID
            audio: 音频数据
            sr: 采样率
            
        Returns:
            验证结果
        """
        if speaker_id not in self.voice_profiles:
            return {
                "verified": False,
                "confidence": 0.0,
                "reason": "speaker_not_registered",
            }
        
        # 提取嵌入
        query_embedding = self.extract_embedding(audio, sr)
        profile_embedding = self.voice_profiles[speaker_id]
        
        # 计算相似度
        similarity = self._cosine_similarity(query_embedding, profile_embedding)
        
        # 验证
        verified = similarity >= self.VERIFICATION_THRESHOLD
        
        return {
            "verified": verified,
            "confidence": round(similarity, 4),
            "threshold": self.VERIFICATION_THRESHOLD,
        }
    
    def update_profile(
        self, 
        speaker_id: str, 
        audio: np.ndarray,
        sr: int = 16000,
        alpha: float = 0.3
    ) -> Dict:
        """
        更新声纹档案（增量学习）
        
        Args:
            speaker_id: 说话人ID
            audio: 新音频样本
            sr: 采样率
            alpha: 更新权重 (0-1)
            
        Returns:
            更新结果
        """
        if speaker_id not in self.voice_profiles:
            raise ValueError(f"Speaker {speaker_id} not registered")
        
        # 提取新嵌入
        new_embedding = self.extract_embedding(audio, sr)
        
        # 加权平均更新
        old_embedding = self.voice_profiles[speaker_id]
        updated_embedding = (1 - alpha) * old_embedding + alpha * new_embedding
        updated_embedding = updated_embedding / (np.linalg.norm(updated_embedding) + 1e-8)
        
        # 存储
        self.voice_profiles[speaker_id] = updated_embedding
        
        # 计算变化
        similarity = self._cosine_similarity(old_embedding, updated_embedding)
        
        return {
            "speaker_id": speaker_id,
            "updated": True,
            "similarity_with_previous": round(similarity, 4),
        }
    
    def delete_profile(self, speaker_id: str) -> bool:
        """删除声纹档案"""
        if speaker_id in self.voice_profiles:
            del self.voice_profiles[speaker_id]
            return True
        return False
    
    def get_profile(self, speaker_id: str) -> Optional[np.ndarray]:
        """获取声纹档案"""
        return self.voice_profiles.get(speaker_id)
    
    def list_profiles(self) -> List[str]:
        """列出所有已注册说话人"""
        return list(self.voice_profiles.keys())
    
    def get_stats(self) -> Dict:
        """获取统计信息"""
        return {
            "total_profiles": len(self.voice_profiles),
            "embedding_dim": self.embedding_dim,
            "recognition_threshold": self.RECOGNITION_THRESHOLD,
            "verification_threshold": self.VERIFICATION_THRESHOLD,
            "use_ml_model": self.use_ml_model,
        }
