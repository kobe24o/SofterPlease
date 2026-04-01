"""
反馈生成器 - 根据情绪状态生成个性化干预建议

策略包括：
- 呼吸练习
- 数数冷静
- 暂停建议
- 积极提醒
"""

from __future__ import annotations

import random
from typing import Dict, List, Optional
from dataclasses import dataclass
from datetime import datetime


@dataclass
class FeedbackMessage:
    """反馈消息"""
    level: str  # calm, mild, moderate, high, extreme
    message: str
    message_type: str  # text, audio, haptic
    strategy: str  # breathing, counting, pausing, suggestion, encouragement
    duration_seconds: int  # 建议执行时间
    
    def to_dict(self) -> Dict:
        return {
            "level": self.level,
            "message": self.message,
            "message_type": self.message_type,
            "strategy": self.strategy,
            "duration_seconds": self.duration_seconds,
        }


class FeedbackGenerator:
    """
    个性化反馈生成器
    
    根据用户情绪状态、历史数据、个人偏好生成最适合的干预建议
    """
    
    # 反馈消息库
    FEEDBACK_MESSAGES = {
        "calm": {
            "breathing": [
                "保持现在的状态，深呼吸三次。",
                "很好，继续保持平稳的呼吸。",
                "你的语气很温和，继续保持。",
            ],
            "encouragement": [
                "沟通很顺畅，继续保持！",
                "这样的交流方式很好。",
                "你们聊得很融洽。",
            ],
        },
        "mild": {
            "breathing": [
                "稍微放慢一点语速，深呼吸。",
                "试着放松肩膀，深呼吸一次。",
                "保持冷静，慢慢说。",
            ],
            "suggestion": [
                "可以先听对方说完。",
                "试着用更柔和的语调。",
                "换个角度思考一下。",
            ],
        },
        "moderate": {
            "breathing": [
                "先停下来，深呼吸三次。",
                "吸气...呼气...放松。",
                "慢慢呼吸，让自己冷静下来。",
            ],
            "counting": [
                "从1数到10，然后再继续。",
                "在心里默数5个数。",
                "暂停一下，数到5。",
            ],
            "pausing": [
                "先暂停一下，给自己10秒钟。",
                "喝口水，休息一下。",
                "先停一停，整理一下思路。",
            ],
        },
        "high": {
            "breathing": [
                "你现在有点激动，先深呼吸五次。",
                "吸气4秒，憋气4秒，呼气6秒。",
                "跟着节奏：吸-呼-吸-呼。",
            ],
            "counting": [
                "从1慢慢数到10。",
                "倒数：10、9、8...1。",
                "每数一个数，放松一点。",
            ],
            "pausing": [
                "建议暂停对话30秒。",
                "先离开一下，冷静后再回来。",
                "给自己一点时间平复情绪。",
            ],
        },
        "extreme": {
            "breathing": [
                "请立即停止，做深呼吸！",
                "现在需要冷静下来，深呼吸！",
                "吸气...呼气...重复5次！",
            ],
            "counting": [
                "必须停下来！从1数到20！",
                "立刻开始倒数：20、19、18...",
                "数到10之前不要说话！",
            ],
            "pausing": [
                "建议立即暂停对话！",
                "先分开一下，等冷静了再谈！",
                "现在不适合继续讨论，先暂停！",
            ],
        },
    }
    
    # 策略优先级（根据情绪等级）
    STRATEGY_PRIORITY = {
        "calm": ["encouragement", "breathing"],
        "mild": ["breathing", "suggestion"],
        "moderate": ["breathing", "counting", "pausing"],
        "high": ["pausing", "breathing", "counting"],
        "extreme": ["pausing", "counting", "breathing"],
    }
    
    # 策略执行时间建议
    STRATEGY_DURATION = {
        "breathing": 15,
        "counting": 10,
        "pausing": 30,
        "suggestion": 5,
        "encouragement": 3,
    }
    
    def __init__(self):
        # 用户偏好 {user_id: {preferred_strategy, feedback_frequency}}
        self.user_preferences: Dict[str, Dict] = {}
        
        # 反馈历史 {user_id: [(timestamp, strategy, effectiveness)]}
        self.feedback_history: Dict[str, List] = {}
        
        # 连续反馈计数（避免过度干预）
        self.consecutive_feedback_count: Dict[str, int] = {}
    
    def set_user_preference(
        self, 
        user_id: str, 
        preferred_strategy: Optional[str] = None,
        feedback_frequency: str = "normal"  # low, normal, high
    ):
        """设置用户偏好"""
        self.user_preferences[user_id] = {
            "preferred_strategy": preferred_strategy,
            "feedback_frequency": feedback_frequency,
        }
    
    def generate_feedback(
        self,
        user_id: str,
        emotion_level: str,
        anger_score: float,
        context: Optional[Dict] = None
    ) -> Optional[FeedbackMessage]:
        """
        生成反馈消息
        
        Args:
            user_id: 用户ID
            emotion_level: 情绪等级
            anger_score: 愤怒分数
            context: 上下文信息
            
        Returns:
            FeedbackMessage 或 None（如果不需要反馈）
        """
        # 检查反馈频率
        if not self._should_provide_feedback(user_id, emotion_level):
            return None
        
        # 选择策略
        strategy = self._select_strategy(user_id, emotion_level)
        
        # 选择消息
        message = self._select_message(emotion_level, strategy)
        
        # 个性化调整
        message = self._personalize_message(message, user_id, context)
        
        # 更新计数
        self._update_feedback_count(user_id, emotion_level)
        
        return FeedbackMessage(
            level=emotion_level,
            message=message,
            message_type="text",
            strategy=strategy,
            duration_seconds=self.STRATEGY_DURATION.get(strategy, 10),
        )
    
    def _should_provide_feedback(self, user_id: str, emotion_level: str) -> bool:
        """判断是否应该提供反馈"""
        # 平静状态不需要干预
        if emotion_level == "calm":
            # 偶尔给予鼓励
            return random.random() < 0.1
        
        # 获取用户频率偏好
        preference = self.user_preferences.get(user_id, {})
        frequency = preference.get("feedback_frequency", "normal")
        
        # 获取连续反馈计数
        count = self.consecutive_feedback_count.get(user_id, 0)
        
        # 根据频率和情绪等级决定是否反馈
        if frequency == "low":
            # 低频：只在高情绪时反馈，且间隔较长
            if emotion_level in ["high", "extreme"]:
                return count >= 2
            return False
        
        elif frequency == "high":
            # 高频：几乎所有情况都反馈
            if emotion_level in ["moderate", "high", "extreme"]:
                return True
            return count >= 1
        
        else:  # normal
            # 正常频率
            if emotion_level in ["high", "extreme"]:
                return True
            if emotion_level == "moderate":
                return count >= 1
            return count >= 2
    
    def _select_strategy(self, user_id: str, emotion_level: str) -> str:
        """选择反馈策略"""
        # 检查用户偏好
        preference = self.user_preferences.get(user_id, {})
        preferred = preference.get("preferred_strategy")
        
        # 如果用户有偏好且该策略适用于当前情绪等级，优先使用
        if preferred:
            available = self.FEEDBACK_MESSAGES.get(emotion_level, {})
            if preferred in available:
                return preferred
        
        # 根据优先级选择
        priorities = self.STRATEGY_PRIORITY.get(emotion_level, ["breathing"])
        
        # 考虑历史效果
        history = self.feedback_history.get(user_id, [])
        if history:
            # 找出最有效的策略
            strategy_effectiveness = {}
            for _, strategy, effectiveness in history[-20:]:  # 最近20次
                if strategy not in strategy_effectiveness:
                    strategy_effectiveness[strategy] = []
                strategy_effectiveness[strategy].append(effectiveness)
            
            # 计算平均效果
            avg_effectiveness = {
                s: sum(scores) / len(scores) 
                for s, scores in strategy_effectiveness.items()
            }
            
            # 按效果排序优先级
            if avg_effectiveness:
                sorted_strategies = sorted(
                    priorities,
                    key=lambda s: avg_effectiveness.get(s, 0.5),
                    reverse=True
                )
                return sorted_strategies[0]
        
        return priorities[0]
    
    def _select_message(self, emotion_level: str, strategy: str) -> str:
        """选择具体消息"""
        messages = self.FEEDBACK_MESSAGES.get(emotion_level, {})
        strategy_messages = messages.get(strategy, ["请冷静下来。"])
        return random.choice(strategy_messages)
    
    def _personalize_message(self, message: str, user_id: str, context: Optional[Dict]) -> str:
        """个性化消息"""
        if not context:
            return message
        
        # 添加称呼
        nickname = context.get("nickname")
        if nickname and random.random() < 0.3:  # 30%概率添加称呼
            message = f"{nickname}，{message}"
        
        return message
    
    def _update_feedback_count(self, user_id: str, emotion_level: str):
        """更新反馈计数"""
        if emotion_level == "calm":
            # 平静状态重置计数
            self.consecutive_feedback_count[user_id] = 0
        else:
            self.consecutive_feedback_count[user_id] = \
                self.consecutive_feedback_count.get(user_id, 0) + 1
    
    def record_effectiveness(
        self, 
        user_id: str, 
        strategy: str, 
        effectiveness: float,
        subsequent_anger_change: float
    ):
        """记录反馈效果"""
        if user_id not in self.feedback_history:
            self.feedback_history[user_id] = []
        
        self.feedback_history[user_id].append({
            "timestamp": datetime.now(),
            "strategy": strategy,
            "effectiveness": effectiveness,
            "anger_change": subsequent_anger_change,
        })
        
        # 限制历史记录大小
        if len(self.feedback_history[user_id]) > 100:
            self.feedback_history[user_id] = self.feedback_history[user_id][-100:]
    
    def get_user_stats(self, user_id: str) -> Dict:
        """获取用户反馈统计"""
        history = self.feedback_history.get(user_id, [])
        
        if not history:
            return {
                "total_feedback_count": 0,
                "average_effectiveness": 0.0,
                "most_effective_strategy": None,
            }
        
        # 统计各策略效果
        strategy_stats = {}
        for record in history:
            strategy = record["strategy"]
            if strategy not in strategy_stats:
                strategy_stats[strategy] = []
            strategy_stats[strategy].append(record["effectiveness"])
        
        # 计算平均效果
        avg_effectiveness = {
            s: sum(scores) / len(scores)
            for s, scores in strategy_stats.items()
        }
        
        most_effective = max(avg_effectiveness.items(), key=lambda x: x[1])[0] \
            if avg_effectiveness else None
        
        return {
            "total_feedback_count": len(history),
            "average_effectiveness": round(sum(r["effectiveness"] for r in history) / len(history), 4),
            "most_effective_strategy": most_effective,
            "strategy_breakdown": {
                s: {"count": len(scores), "avg_effectiveness": round(sum(scores) / len(scores), 4)}
                for s, scores in strategy_stats.items()
            },
        }
    
    def generate_summary_feedback(self, daily_stats: Dict) -> List[FeedbackMessage]:
        """生成每日总结反馈"""
        messages = []
        
        avg_anger = daily_stats.get("avg_anger_score", 0)
        high_count = daily_stats.get("high_emotion_count", 0)
        improvement = daily_stats.get("improvement_score", 0)
        
        # 根据表现生成总结
        if improvement > 0.2:
            messages.append(FeedbackMessage(
                level="calm",
                message="今天你的情绪管理有明显进步！继续保持。",
                message_type="text",
                strategy="encouragement",
                duration_seconds=3,
            ))
        
        if high_count > 5:
            messages.append(FeedbackMessage(
                level="moderate",
                message=f"今天有{high_count}次情绪波动，建议关注触发因素。",
                message_type="text",
                strategy="suggestion",
                duration_seconds=5,
            ))
        
        if avg_anger < 0.3:
            messages.append(FeedbackMessage(
                level="calm",
                message="今天的整体情绪状态很好，家庭氛围很和谐！",
                message_type="text",
                strategy="encouragement",
                duration_seconds=3,
            ))
        
        return messages
