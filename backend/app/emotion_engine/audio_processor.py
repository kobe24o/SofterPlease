"""
音频处理器 - 音频预处理和特征提取

功能：
- 音频格式转换
- 降噪处理
- 语音活动检测 (VAD)
- 音频分段
"""

from __future__ import annotations

import numpy as np
from typing import List, Tuple, Optional, Dict
from dataclasses import dataclass
import librosa
import io
import wave


@dataclass
class AudioSegment:
    """音频片段"""
    audio: np.ndarray
    start_time: float  # 秒
    end_time: float
    is_speech: bool
    
    @property
    def duration(self) -> float:
        return self.end_time - self.start_time


@dataclass
class ProcessedAudio:
    """处理后的音频"""
    audio: np.ndarray
    sample_rate: int
    segments: List[AudioSegment]
    
    def get_speech_segments(self) -> List[AudioSegment]:
        """获取语音片段"""
        return [s for s in self.segments if s.is_speech]
    
    def get_total_speech_duration(self) -> float:
        """获取总语音时长"""
        return sum(s.duration for s in self.get_speech_segments())


class AudioProcessor:
    """
    音频处理器
    
    提供音频预处理功能，为情绪分析做准备
    """
    
    def __init__(
        self,
        target_sample_rate: int = 16000,
        frame_duration_ms: int = 30,
        vad_aggressiveness: int = 2,
    ):
        self.target_sample_rate = target_sample_rate
        self.frame_duration_ms = frame_duration_ms
        self.vad_aggressiveness = vad_aggressiveness
        
        # VAD参数
        self.vad_frame_length = int(target_sample_rate * frame_duration_ms / 1000)
        self.vad_hop_length = self.vad_frame_length // 2
    
    def load_audio(
        self, 
        audio_data: bytes,
        format: str = "wav"
    ) -> Tuple[np.ndarray, int]:
        """
        加载音频数据
        
        Args:
            audio_data: 音频字节数据
            format: 音频格式 (wav, mp3, etc.)
            
        Returns:
            (音频数组, 采样率)
        """
        if format.lower() == "wav":
            # 使用wave解析WAV文件
            with io.BytesIO(audio_data) as wav_io:
                with wave.open(wav_io, 'rb') as wav_file:
                    n_channels = wav_file.getnchannels()
                    sample_width = wav_file.getsampwidth()
                    sample_rate = wav_file.getframerate()
                    n_frames = wav_file.getnframes()
                    
                    # 读取原始数据
                    raw_data = wav_file.readframes(n_frames)
                    
                    # 转换为numpy数组
                    if sample_width == 2:
                        audio = np.frombuffer(raw_data, dtype=np.int16)
                    elif sample_width == 4:
                        audio = np.frombuffer(raw_data, dtype=np.int32)
                    else:
                        raise ValueError(f"Unsupported sample width: {sample_width}")
                    
                    # 转换为float32
                    audio = audio.astype(np.float32) / (2 ** (sample_width * 8 - 1))
                    
                    # 如果是立体声，转换为单声道
                    if n_channels == 2:
                        audio = audio.reshape(-1, 2).mean(axis=1)
                    
                    return audio, sample_rate
        else:
            # 使用librosa加载其他格式
            with io.BytesIO(audio_data) as audio_io:
                audio, sr = librosa.load(audio_io, sr=None, mono=True)
                return audio, sr
    
    def preprocess(
        self, 
        audio: np.ndarray, 
        source_sr: int,
        apply_noise_reduction: bool = True,
        normalize: bool = True
    ) -> ProcessedAudio:
        """
        预处理音频
        
        Args:
            audio: 音频数组
            source_sr: 原始采样率
            apply_noise_reduction: 是否应用降噪
            normalize: 是否归一化
            
        Returns:
            ProcessedAudio
        """
        # 1. 重采样
        if source_sr != self.target_sample_rate:
            audio = librosa.resample(audio, orig_sr=source_sr, target_sr=self.target_sample_rate)
        
        # 2. 降噪
        if apply_noise_reduction:
            audio = self._reduce_noise(audio)
        
        # 3. 归一化
        if normalize:
            audio = self._normalize_audio(audio)
        
        # 4. 语音活动检测和分段
        segments = self._segment_audio(audio)
        
        return ProcessedAudio(
            audio=audio,
            sample_rate=self.target_sample_rate,
            segments=segments,
        )
    
    def _reduce_noise(self, audio: np.ndarray) -> np.ndarray:
        """简单降噪处理"""
        # 使用频谱减法进行降噪
        # 1. 估计噪声谱（假设前100ms是噪声）
        noise_sample_duration = min(int(0.1 * self.target_sample_rate), len(audio) // 10)
        noise_sample = audio[:noise_sample_duration]
        
        # 2. 计算噪声的STFT
        noise_stft = librosa.stft(noise_sample)
        noise_mag = np.abs(noise_stft)
        noise_profile = np.mean(noise_mag, axis=1, keepdims=True)
        
        # 3. 对完整音频进行STFT
        audio_stft = librosa.stft(audio)
        audio_mag = np.abs(audio_stft)
        audio_phase = np.angle(audio_stft)
        
        # 4. 频谱减法
        clean_mag = np.maximum(audio_mag - noise_profile * 1.5, 0)
        
        # 5. 重建音频
        clean_stft = clean_mag * np.exp(1j * audio_phase)
        clean_audio = librosa.istft(clean_stft, length=len(audio))
        
        return clean_audio
    
    def _normalize_audio(self, audio: np.ndarray) -> np.ndarray:
        """音频归一化"""
        # 去除直流偏移
        audio = audio - np.mean(audio)
        
        # 峰值归一化
        max_val = np.max(np.abs(audio))
        if max_val > 0:
            audio = audio / max_val * 0.95
        
        return audio
    
    def _segment_audio(self, audio: np.ndarray) -> List[AudioSegment]:
        """
        音频分段（语音活动检测）
        
        使用基于能量的简单VAD
        """
        segments = []
        
        # 计算帧能量
        frame_length = self.vad_frame_length
        hop_length = self.vad_hop_length
        
        frames = librosa.util.frame(audio, frame_length=frame_length, hop_length=hop_length)
        energies = np.sum(frames ** 2, axis=0)
        
        # 计算阈值（基于中位数）
        threshold = np.median(energies) * 2
        
        # 标记语音帧
        is_speech_frames = energies > threshold
        
        # 合并连续的帧
        min_speech_frames = int(0.2 * self.target_sample_rate / hop_length)  # 至少200ms
        min_silence_frames = int(0.3 * self.target_sample_rate / hop_length)  # 至少300ms静音才分割
        
        # 去除过短的语音段
        is_speech_frames = self._remove_short_segments(
            is_speech_frames, min_speech_frames, True
        )
        
        # 去除过短的静音段
        is_speech_frames = self._remove_short_segments(
            is_speech_frames, min_silence_frames, False
        )
        
        # 生成片段
        in_speech = False
        segment_start = 0
        
        for i, is_speech in enumerate(is_speech_frames):
            time = i * hop_length / self.target_sample_rate
            
            if is_speech and not in_speech:
                # 语音开始
                segment_start = time
                in_speech = True
            elif not is_speech and in_speech:
                # 语音结束
                segments.append(AudioSegment(
                    audio=audio[int(segment_start * self.target_sample_rate):int(time * self.target_sample_rate)],
                    start_time=segment_start,
                    end_time=time,
                    is_speech=True,
                ))
                in_speech = False
        
        # 处理最后一个片段
        if in_speech:
            segments.append(AudioSegment(
                audio=audio[int(segment_start * self.target_sample_rate):],
                start_time=segment_start,
                end_time=len(audio) / self.target_sample_rate,
                is_speech=True,
            ))
        
        # 如果没有检测到语音，返回整个音频作为非语音段
        if not segments:
            segments.append(AudioSegment(
                audio=audio,
                start_time=0,
                end_time=len(audio) / self.target_sample_rate,
                is_speech=False,
            ))
        
        return segments
    
    def _remove_short_segments(
        self, 
        frames: np.ndarray, 
        min_length: int,
        remove_speech: bool
    ) -> np.ndarray:
        """去除过短的片段"""
        result = frames.copy()
        target_value = remove_speech
        
        i = 0
        while i < len(result):
            if result[i] == target_value:
                # 找到一段
                start = i
                while i < len(result) and result[i] == target_value:
                    i += 1
                end = i
                
                # 如果太短，翻转
                if end - start < min_length:
                    result[start:end] = not target_value
            else:
                i += 1
        
        return result
    
    def extract_features(self, audio: np.ndarray) -> Dict:
        """提取音频特征"""
        features = {}
        
        # 基本特征
        features["duration"] = len(audio) / self.target_sample_rate
        features["rms"] = float(np.sqrt(np.mean(audio ** 2)))
        features["zero_crossing_rate"] = float(np.mean(librosa.feature.zero_crossing_rate(audio)))
        
        # 频谱特征
        spectral_centroid = librosa.feature.spectral_centroid(y=audio, sr=self.target_sample_rate)[0]
        features["spectral_centroid_mean"] = float(np.mean(spectral_centroid))
        features["spectral_centroid_std"] = float(np.std(spectral_centroid))
        
        # MFCC
        mfccs = librosa.feature.mfcc(y=audio, sr=self.target_sample_rate, n_mfcc=13)
        for i in range(13):
            features[f"mfcc_{i}_mean"] = float(np.mean(mfccs[i]))
            features[f"mfcc_{i}_std"] = float(np.std(mfccs[i]))
        
        return features
    
    def split_audio(
        self, 
        audio: np.ndarray, 
        segment_duration: float = 5.0,
        overlap: float = 1.0
    ) -> List[np.ndarray]:
        """
        将音频分割成固定长度的片段
        
        Args:
            audio: 音频数组
            segment_duration: 每段时长（秒）
            overlap: 重叠时长（秒）
            
        Returns:
            音频片段列表
        """
        segment_samples = int(segment_duration * self.target_sample_rate)
        overlap_samples = int(overlap * self.target_sample_rate)
        hop_samples = segment_samples - overlap_samples
        
        segments = []
        start = 0
        
        while start < len(audio):
            end = min(start + segment_samples, len(audio))
            segment = audio[start:end]
            
            # 如果片段太短，跳过
            if len(segment) >= self.target_sample_rate:  # 至少1秒
                segments.append(segment)
            
            start += hop_samples
        
        return segments
    
    def convert_format(
        self, 
        audio: np.ndarray, 
        target_format: str = "wav"
    ) -> bytes:
        """
        转换音频格式
        
        Args:
            audio: 音频数组
            target_format: 目标格式
            
        Returns:
            音频字节数据
        """
        if target_format.lower() == "wav":
            # 转换为16位整数
            audio_int16 = (audio * 32767).astype(np.int16)
            
            # 创建WAV文件
            buffer = io.BytesIO()
            with wave.open(buffer, 'wb') as wav_file:
                wav_file.setnchannels(1)  # 单声道
                wav_file.setsampwidth(2)  # 16位
                wav_file.setframerate(self.target_sample_rate)
                wav_file.writeframes(audio_int16.tobytes())
            
            return buffer.getvalue()
        else:
            raise ValueError(f"Unsupported target format: {target_format}")
