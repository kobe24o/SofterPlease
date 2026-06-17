// SofterPlease - 前端主脚本

const API_BASE_URL = 'http://localhost:8000';

// 全局状态
const state = {
  user: null,
  token: null,
  currentFamily: null,
  currentSession: null,
  ws: null,
  charts: {},
  realtimeData: [],
  currentFeedbackToken: null,
  modelDebugSession: null,
};

// 工具函数
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

const formatDate = (date) => {
  return new Date(date).toLocaleDateString('zh-CN');
};

const formatTime = (date) => {
  return new Date(date).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
};

const getEmotionIcon = (level) => {
  const icons = {
    calm: '😊',
    mild: '🙂',
    moderate: '😤',
    high: '😠',
    extreme: '🤬',
  };
  return icons[level] || '😐';
};

const getEmotionText = (level) => {
  const texts = {
    calm: '平静',
    mild: '轻微',
    moderate: '中等',
    high: '较高',
    extreme: '极高',
  };
  return texts[level] || '未知';
};

// API 调用
const api = {
  async request(endpoint, options = {}) {
    const url = `${API_BASE_URL}${endpoint}`;
    const headers = {
      'Content-Type': 'application/json',
      ...options.headers,
    };
    
    if (state.token) {
      headers['Authorization'] = `Bearer ${state.token}`;
    }
    
    const response = await fetch(url, {
      ...options,
      headers,
    });
    
    if (!response.ok) {
      const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
      throw new Error(error.detail || `HTTP ${response.status}`);
    }
    
    return response.json();
  },
  
  async createUser(nickname) {
    return this.request('/v1/users', {
      method: 'POST',
      body: JSON.stringify({ nickname }),
    });
  },
  
  async login(userId) {
    return this.request('/v1/auth/login', {
      method: 'POST',
      body: JSON.stringify({ user_id: userId }),
    });
  },
  
  async getMe() {
    return this.request('/v1/users/me');
  },

  async getSystemInfo() {
    return this.request('/v1/system/info');
  },

  async preloadEmotionModel() {
    return this.request('/v1/system/emotion-model/load', {
      method: 'POST',
    });
  },

  async getDebugAudio(limit = 30) {
    return this.request(`/v1/debug/audio?limit=${limit}`);
  },

  async labelDebugAudio(recordId, label) {
    return this.request(`/v1/debug/audio/${recordId}/label`, {
      method: 'POST',
      body: JSON.stringify({ label }),
    });
  },

  async getTrainingCorpus() {
    return this.request('/v1/training/corpus');
  },

  async updateTrainingCorpus(ids, changes) {
    return this.request('/v1/training/corpus/update', {
      method: 'POST',
      body: JSON.stringify({ ids, ...changes }),
    });
  },

  async startTrainingJob(payload) {
    return this.request('/v1/training/jobs', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
  },

  async getCurrentTrainingJob() {
    return this.request('/v1/training/jobs/current');
  },

  async getTrainingModels() {
    return this.request('/v1/training/models');
  },

  async loadTrainingModel(version) {
    return this.request('/v1/training/models/load', {
      method: 'POST',
      body: JSON.stringify({ version }),
    });
  },
  
  async createFamily(name) {
    return this.request('/v1/families', {
      method: 'POST',
      body: JSON.stringify({ name }),
    });
  },
  
  async joinFamily(inviteCode) {
    return this.request('/v1/families/join', {
      method: 'POST',
      body: JSON.stringify({ invite_code: inviteCode }),
    });
  },
  
  async getFamily(familyId) {
    return this.request(`/v1/families/${familyId}`);
  },
  
  async startSession(familyId, deviceId, deviceType = 'web') {
    return this.request('/v1/sessions/start', {
      method: 'POST',
      body: JSON.stringify({ family_id: familyId, device_id: deviceId, device_type: deviceType }),
    });
  },
  
  async endSession(sessionId) {
    return this.request('/v1/sessions/end', {
      method: 'POST',
      body: JSON.stringify({ session_id: sessionId }),
    });
  },
  
  async getDailyReport(familyId, date) {
    return this.request(`/v1/reports/daily/${familyId}?date=${date}`);
  },
  
  async getTimeSeries(sessionId) {
    return this.request(`/v1/reports/timeseries/${sessionId}`);
  },
  
  async postFeedbackAction(feedbackToken, action) {
    return this.request('/v1/feedback/actions', {
      method: 'POST',
      body: JSON.stringify({ feedback_token: feedbackToken, action }),
    });
  },
  
  async createGoal(familyId, goalData) {
    return this.request(`/v1/goals?family_id=${familyId}`, {
      method: 'POST',
      body: JSON.stringify(goalData),
    });
  },
  
  async getGoals(familyId) {
    return this.request(`/v1/goals?family_id=${familyId}`);
  },
  
  async trackEvent(eventName, properties = {}) {
    return this.request('/v1/analytics/events', {
      method: 'POST',
      body: JSON.stringify({ event_name: eventName, properties }),
    });
  },
};

// WebSocket 连接
const ws = {
  connect() {
    const wsUrl = API_BASE_URL.replace('http', 'ws') + '/v1/realtime/ws';
    state.ws = new WebSocket(wsUrl);
    
    state.ws.onopen = () => {
      console.log('WebSocket connected');
    };
    
    state.ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      this.handleMessage(data);
    };
    
    state.ws.onclose = () => {
      console.log('WebSocket disconnected');
      // 尝试重连
      setTimeout(() => this.connect(), 3000);
    };
    
    state.ws.onerror = (error) => {
      console.error('WebSocket error:', error);
    };
  },
  
  handleMessage(data) {
    if (data.type === 'analysis_result') {
      updateRealtimeDisplay(data);
      if (data.feedback) {
        showFeedback(data.feedback);
      }
    } else if (data.type === 'feedback_action_confirmed') {
      hideFeedbackActions();
    }
  },
  
  send(message) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify(message));
    }
  },
  
  analyze(sessionId, speakerId, angerScore, transcript = '') {
    this.send({
      type: 'analyze',
      session_id: sessionId,
      speaker_id: speakerId,
      anger_score: angerScore,
      transcript,
    });
  },
  
  feedbackAction(feedbackToken, action) {
    this.send({
      type: 'feedback_action',
      feedback_token: feedbackToken,
      action,
    });
  },
};

// 页面导航
const navigation = {
  currentPage: 'dashboard',
  
  init() {
    $$('.nav-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const page = item.dataset.page;
        this.navigateTo(page);
      });
    });
  },
  
  navigateTo(page) {
    // 更新导航状态
    $$('.nav-item').forEach(item => {
      item.classList.toggle('active', item.dataset.page === page);
    });
    
    // 隐藏所有页面
    $$('.content-page').forEach(p => p.classList.add('hidden'));
    
    // 显示目标页面
    const targetPage = $(`#${page}Page`);
    if (targetPage) {
      targetPage.classList.remove('hidden');
      targetPage.classList.add('slide-in');
    }
    
    this.currentPage = page;
    
    // 加载页面数据
    this.loadPageData(page);
  },
  
  loadPageData(page) {
    switch (page) {
      case 'dashboard':
        loadDashboardData();
        break;
      case 'realtime':
        initRealtimePage();
        break;
      case 'reports':
        loadReportsData();
        break;
      case 'goals':
        loadGoalsData();
        break;
      case 'family':
        loadFamilyData();
        break;
      case 'modelDebug':
        initModelDebugPage();
        break;
    }
  },
};

// 登录流程
const auth = {
  async init() {
    // 检查本地存储
    const savedUser = localStorage.getItem('softerplease_user');
    const savedToken = localStorage.getItem('softerplease_token');
    
    if (savedUser && savedToken) {
      state.user = JSON.parse(savedUser);
      state.token = savedToken;
      
      try {
        // 验证token
        const userData = await api.getMe();
        state.user = userData;
        this.showMainPage();
      } catch (error) {
        console.error('Token invalid:', error);
        this.showLoginPage();
      }
    } else {
      this.showLoginPage();
    }
  },
  
  showLoginPage() {
    $('#loginPage').classList.remove('hidden');
    $('#mainPage').classList.add('hidden');
  },
  
  showMainPage() {
    $('#loginPage').classList.add('hidden');
    $('#mainPage').classList.remove('hidden');
    $('#currentUserName').textContent = state.user.nickname;
    
    // 初始化WebSocket
    ws.connect();
    
    // 加载仪表板
    loadDashboardData();
  },
  
  async createUser(nickname) {
    try {
      const user = await api.createUser(nickname);
      const authData = await api.login(user.user_id);
      
      state.user = authData.user;
      state.token = authData.access_token;
      
      // 保存到本地存储
      localStorage.setItem('softerplease_user', JSON.stringify(state.user));
      localStorage.setItem('softerplease_token', state.token);
      
      // 使用自动创建的家庭
      if (state.user.families && state.user.families.length > 0) {
        state.currentFamily = state.user.families[0];
      }
      
      this.showMainPage();
      api.trackEvent('user_created', { nickname });
    } catch (error) {
      alert('创建用户失败: ' + error.message);
    }
  },
  
  logout() {
    localStorage.removeItem('softerplease_user');
    localStorage.removeItem('softerplease_token');
    state.user = null;
    state.token = null;
    state.currentFamily = null;
    state.currentSession = null;
    
    if (state.ws) {
      state.ws.close();
    }
    
    this.showLoginPage();
  },
};

// 仪表板
async function loadDashboardData() {
  if (!state.user || !state.user.families || state.user.families.length === 0) {
    return;
  }
  
  const familyId = state.user.families[0].family_id;
  const today = new Date().toISOString().split('T')[0];
  
  try {
    const report = await api.getDailyReport(familyId, today);
    
    // 更新统计卡片
    $('#todayEmotionScore').textContent = (report.avg_anger_score * 100).toFixed(1);
    $('#todaySessions').textContent = report.session_count;
    $('#todayDuration').textContent = Math.round(report.total_duration_seconds / 60);
    $('#feedbackRate').textContent = (report.feedback_accepted_rate * 100).toFixed(0) + '%';
    
    // 更新趋势
    const trendEl = $('#emotionTrend');
    if (report.trend_direction === 'improving') {
      trendEl.textContent = '↓ 改善中';
      trendEl.className = 'stat-trend positive';
    } else if (report.trend_direction === 'worsening') {
      trendEl.textContent = '↑ 需关注';
      trendEl.className = 'stat-trend negative';
    } else {
      trendEl.textContent = '→ 稳定';
      trendEl.className = 'stat-trend';
    }
    
    // 加载图表
    loadDashboardCharts(familyId);
    
  } catch (error) {
    console.error('Failed to load dashboard:', error);
  }
}

function loadDashboardCharts(familyId) {
  // 情绪趋势图
  const trendCtx = $('#emotionTrendChart');
  if (trendCtx) {
    if (state.charts.trend) {
      state.charts.trend.destroy();
    }
    
    state.charts.trend = new Chart(trendCtx, {
      type: 'line',
      data: {
        labels: ['周一', '周二', '周三', '周四', '周五', '周六', '周日'],
        datasets: [{
          label: '情绪指数',
          data: [0.3, 0.4, 0.35, 0.5, 0.45, 0.3, 0.25],
          borderColor: '#4CAF50',
          backgroundColor: 'rgba(76, 175, 80, 0.1)',
          tension: 0.4,
          fill: true,
        }],
      },
      options: {
        responsive: true,
        plugins: {
          legend: { display: false },
        },
        scales: {
          y: {
            min: 0,
            max: 1,
            ticks: {
              callback: (value) => (value * 100).toFixed(0) + '%',
            },
          },
        },
      },
    });
  }
  
  // 情绪分布图
  const distCtx = $('#emotionDistributionChart');
  if (distCtx) {
    if (state.charts.distribution) {
      state.charts.distribution.destroy();
    }
    
    state.charts.distribution = new Chart(distCtx, {
      type: 'doughnut',
      data: {
        labels: ['平静', '轻微', '中等', '较高', '极高'],
        datasets: [{
          data: [45, 25, 15, 10, 5],
          backgroundColor: [
            '#4CAF50',
            '#8BC34A',
            '#FFC107',
            '#FF9800',
            '#f44336',
          ],
        }],
      },
      options: {
        responsive: true,
        plugins: {
          legend: {
            position: 'bottom',
          },
        },
      },
    });
  }
}

// 实时监测页面
function initRealtimePage() {
  // 初始化实时图表
  const ctx = $('#realtimeChart');
  if (ctx) {
    if (state.charts.realtime) {
      state.charts.realtime.destroy();
    }
    
    state.charts.realtime = new Chart(ctx, {
      type: 'line',
      data: {
        labels: [],
        datasets: [{
          label: '情绪指数',
          data: [],
          borderColor: '#4CAF50',
          backgroundColor: 'rgba(76, 175, 80, 0.1)',
          tension: 0.4,
          fill: true,
        }],
      },
      options: {
        responsive: true,
        animation: false,
        plugins: {
          legend: { display: false },
        },
        scales: {
          y: {
            min: 0,
            max: 1,
          },
        },
      },
    });
  }
  
  // 重置状态
  state.realtimeData = [];
  updateGauge(0);
}

function updateRealtimeDisplay(data) {
  // 更新仪表盘
  updateGauge(data.anger_score);
  
  // 更新状态
  const statusEl = $('#emotionStatus');
  if (statusEl) {
    statusEl.innerHTML = `
      <span class="status-icon">${getEmotionIcon(data.emotion_level)}</span>
      <span class="status-text">${getEmotionText(data.emotion_level)}</span>
    `;
  }
  
  // 更新图表
  if (state.charts.realtime) {
    const chart = state.charts.realtime;
    const time = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    
    chart.data.labels.push(time);
    chart.data.datasets[0].data.push(data.anger_score);
    
    // 保持最多30个数据点
    if (chart.data.labels.length > 30) {
      chart.data.labels.shift();
      chart.data.datasets[0].data.shift();
    }
    
    chart.update('none');
  }
}

function updateGauge(value) {
  const gaugeFill = $('#gaugeFill');
  const gaugeValue = $('#currentEmotionValue');
  
  if (gaugeFill && gaugeValue) {
    // 计算弧形路径
    const angle = value * Math.PI; // 0 to PI
    const x = 100 - 80 * Math.cos(angle);
    const y = 100 - 80 * Math.sin(angle);
    const largeArc = value > 0.5 ? 1 : 0;
    
    gaugeFill.setAttribute('d', `M 20 100 A 80 80 0 ${largeArc} 1 ${x} ${y}`);
    
    // 更新颜色
    let color = '#4CAF50';
    if (value > 0.7) color = '#f44336';
    else if (value > 0.5) color = '#FF9800';
    else if (value > 0.3) color = '#FFC107';
    
    gaugeFill.setAttribute('stroke', color);
    gaugeValue.textContent = (value * 100).toFixed(0);
    gaugeValue.style.color = color;
  }
}

function showFeedback(feedback) {
  const display = $('#feedbackDisplay');
  const actions = $('#feedbackActions');
  
  if (display && actions) {
    display.innerHTML = `<p class="feedback-message">${feedback.message}</p>`;
    actions.classList.remove('hidden');
    state.currentFeedbackToken = feedback.token;
  }
}

function hideFeedbackActions() {
  const actions = $('#feedbackActions');
  if (actions) {
    actions.classList.add('hidden');
  }
  state.currentFeedbackToken = null;
}

// 音频录制相关变量
let mediaRecorder;
let audioChunks = [];
let recordingInterval;
let audioContext;
let analyser;
let dataArray;
let bufferLength;
let stream;

// 会话控制
async function startSession() {
  if (!state.user || !state.user.families || state.user.families.length === 0) {
    alert('请先创建或加入家庭');
    return;
  }
  
  const familyId = state.user.families[0].family_id;
  const deviceId = 'web-' + Math.random().toString(36).substr(2, 9);
  
  try {
    // 开始会话
    const session = await api.startSession(familyId, deviceId, 'web');
    state.currentSession = session;
    
    // 开始麦克风录制
    await startRecording();
    
    $('#startSessionBtn').classList.add('hidden');
    $('#pauseSessionBtn').classList.remove('hidden');
    $('#endSessionBtn').classList.remove('hidden');
    
    api.trackEvent('session_started', { family_id: familyId });
  } catch (error) {
    alert('开始会话失败: ' + error.message);
  }
}

// 开始麦克风录制
async function startRecording() {
  try {
    // 请求麦克风权限
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    
    // 创建音频上下文和分析器
    audioContext = new (window.AudioContext || window.webkitAudioContext)();
    analyser = audioContext.createAnalyser();
    const source = audioContext.createMediaStreamSource(stream);
    source.connect(analyser);
    
    analyser.fftSize = 2048;
    bufferLength = analyser.frequencyBinCount;
    dataArray = new Uint8Array(bufferLength);
    
    // 创建脚本处理器节点用于实时处理音频
    const bufferSize = 4096;
    const scriptProcessor = audioContext.createScriptProcessor(bufferSize, 1, 1);
    
    // 音频数据缓冲区
    const audioBuffer = [];
    
    // 处理音频数据
    scriptProcessor.onaudioprocess = (event) => {
      const inputData = event.inputBuffer.getChannelData(0);
      const outputData = event.outputBuffer.getChannelData(0);
      
      // 复制输入到输出（通过）
      for (let i = 0; i < bufferSize; i++) {
        outputData[i] = inputData[i];
        audioBuffer.push(inputData[i]);
      }
    };
    
    // 连接音频处理链
    source.connect(scriptProcessor);
    scriptProcessor.connect(audioContext.destination);
    
    // 每2秒发送一次音频进行分析
    recordingInterval = setInterval(async () => {
      if (audioBuffer.length > 0) {
        // 复制并清空缓冲区
        const audioData = Float32Array.from(audioBuffer);
        audioBuffer.length = 0;
        
        // 转换为WAV格式
        const wavBlob = audioToWav(audioData, audioContext.sampleRate);
        
        // 发送音频到后端分析
        await analyzeAudio(wavBlob);
      }
    }, 2000);
    
    console.log('麦克风录制已开始');
  } catch (error) {
    console.error('麦克风录制失败:', error);
    alert('无法访问麦克风，请检查权限设置');
  }
}

// 将音频数据转换为WAV格式
function audioToWav(audioData, sampleRate) {
  const numOfChan = 1;
  const length = audioData.length * 2;
  const buffer = new ArrayBuffer(44 + length);
  const view = new DataView(buffer);
  
  // RIFF 标识符
  writeString(view, 0, 'RIFF');
  view.setUint32(4, 36 + length, true);
  writeString(view, 8, 'WAVE');
  
  // fmt 子块
  writeString(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM格式
  view.setUint16(22, numOfChan, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // 字节率
  view.setUint16(32, 2, true); // 块对齐
  view.setUint16(34, 16, true); // 位深度
  
  // data 子块
  writeString(view, 36, 'data');
  view.setUint32(40, length, true);
  
  // 写入音频数据
  const floatTo16BitPCM = (output, offset, input) => {
    for (let i = 0; i < input.length; i++, offset += 2) {
      const s = Math.max(-1, Math.min(1, input[i]));
      output.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
  };
  
  floatTo16BitPCM(view, 44, audioData);
  
  return new Blob([buffer], { type: 'audio/wav' });
}

// 写入字符串到DataView
function writeString(view, offset, string) {
  for (let i = 0; i < string.length; i++) {
    view.setUint8(offset + i, string.charCodeAt(i));
  }
}

// 分析音频
async function analyzeAudio(audioBlob) {
  if (!state.currentSession) return;
  
  try {
    const formData = new FormData();
    formData.append('audio', audioBlob, 'recording.wav');
    formData.append('session_id', state.currentSession.session_id);
    formData.append('device_id', 'web-' + Math.random().toString(36).substr(2, 9));
    
    // 发送音频到后端分析
    const response = await fetch('http://localhost:8000/v1/voice/analyze', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${state.token}`
      },
      body: formData
    });
    
    if (response.ok) {
      const result = await response.json();
      console.log('情绪分析结果:', result);
      
      // 更新实时显示
      updateRealtimeDisplay({
        type: 'analysis_result',
        anger_score: result.anger_score,
        emotion_level: result.emotion_level,
        feedback: result.feedback
      });
    } else {
      console.error('分析失败:', await response.text());
    }
  } catch (error) {
    console.error('分析音频失败:', error);
  }
}

async function endSession() {
  if (!state.currentSession) return;
  
  try {
    // 停止麦克风录制
    stopRecording();
    
    // 结束会话
    await api.endSession(state.currentSession.session_id);
    
    state.currentSession = null;
    
    $('#startSessionBtn').classList.remove('hidden');
    $('#pauseSessionBtn').classList.add('hidden');
    $('#endSessionBtn').classList.add('hidden');
    
    api.trackEvent('session_ended');
  } catch (error) {
    alert('结束会话失败: ' + error.message);
  }
}

// 停止麦克风录制
function stopRecording() {
  if (recordingInterval) {
    clearInterval(recordingInterval);
    recordingInterval = null;
  }
  
  if (audioContext) {
    audioContext.close();
    audioContext = null;
  }
  
  // 关闭媒体流
  if (stream) {
    stream.getTracks().forEach(track => track.stop());
    stream = null;
  }
  
  console.log('麦克风录制已停止');
}

// 报告页面
function loadReportsData() {
  // 加载报告图表
  const trendCtx = $('#reportTrendChart');
  if (trendCtx) {
    if (state.charts.reportTrend) {
      state.charts.reportTrend.destroy();
    }
    
    state.charts.reportTrend = new Chart(trendCtx, {
      type: 'line',
      data: {
        labels: Array.from({ length: 7 }, (_, i) => {
          const d = new Date();
          d.setDate(d.getDate() - (6 - i));
          return `${d.getMonth() + 1}/${d.getDate()}`;
        }),
        datasets: [{
          label: '平均情绪指数',
          data: [0.35, 0.42, 0.38, 0.45, 0.40, 0.33, 0.30],
          borderColor: '#4CAF50',
          backgroundColor: 'rgba(76, 175, 80, 0.1)',
          tension: 0.4,
          fill: true,
        }],
      },
      options: {
        responsive: true,
        plugins: {
          legend: { display: false },
        },
        scales: {
          y: {
            min: 0,
            max: 1,
          },
        },
      },
    });
  }
}

// 目标页面
async function loadGoalsData() {
  if (!state.user || !state.user.families || state.user.families.length === 0) return;
  
  const familyId = state.user.families[0].family_id;
  
  try {
    const data = await api.getGoals(familyId);
    const container = $('#goalsList');
    
    if (container) {
      if (data.goals.length === 0) {
        container.innerHTML = '<p class="empty-state">暂无目标，点击右上角创建</p>';
      } else {
        container.innerHTML = data.goals.map(goal => `
          <div class="goal-card">
            <div class="goal-header">
              <span class="goal-title">${goal.title}</span>
              <span class="goal-status ${goal.status}">${goal.status === 'active' ? '进行中' : goal.status}</span>
            </div>
            <p>${goal.description || ''}</p>
            <div class="goal-progress">
              <div class="progress-bar">
                <div class="progress-fill" style="width: ${goal.progress_percentage}%"></div>
              </div>
              <p class="progress-text">${goal.current_value} / ${goal.target_value} ${goal.unit} (${goal.progress_percentage.toFixed(1)}%)</p>
            </div>
          </div>
        `).join('');
      }
    }
  } catch (error) {
    console.error('Failed to load goals:', error);
  }
}

// 家庭页面
async function loadFamilyData() {
  if (!state.user || !state.user.families || state.user.families.length === 0) return;
  
  const familyId = state.user.families[0].family_id;
  
  try {
    const family = await api.getFamily(familyId);
    
    // 更新成员列表
    const container = $('#familyMembersList');
    if (container) {
      container.innerHTML = family.members.map(member => `
        <div class="member-card">
          <div class="member-avatar">${member.nickname[0]}</div>
          <div class="member-info">
            <h4>${member.nickname}</h4>
            <p>${member.role === 'owner' ? '家庭管理员' : '成员'}</p>
          </div>
          <span class="member-role">${member.role}</span>
        </div>
      `).join('');
    }
    
    // 更新邀请码
    $('#familyInviteCode').textContent = family.invite_code || '----';
    
  } catch (error) {
    console.error('Failed to load family:', error);
  }
}

// 模型调试页面
let debugMediaRecorder;
let debugRecordedChunks = [];
let debugRecordedBlob;
let debugStream;
let debugWavBlob;
let debugRecordStartedAt;
let debugRecordTimerInterval;
let debugAudioContext;
let debugAudioSource;
let debugAnalyser;
let debugLevelData;
let debugLevelInterval;
let debugCaptureSampleRate = 16000;
let debugPeakLevel = 0;
let debugRmsLevel = 0;
let trainingCorpusItems = [];
let trainingPollTimer;

function setDebugBadge(selector, text, type = '') {
  const el = $(selector);
  if (!el) return;
  el.textContent = text;
  el.className = `status-badge ${type}`.trim();
}

function setDebugText(selector, text) {
  const el = $(selector);
  if (el) {
    el.textContent = text ?? '--';
  }
}

function formatDebugValue(value) {
  if (value === null || value === undefined) return '--';
  if (typeof value === 'number') {
    return Number.isInteger(value) ? String(value) : value.toFixed(4);
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return String(value);
}

function renderDebugTable(selector, data) {
  const el = $(selector);
  if (!el) return;

  if (!data || Object.keys(data).length === 0) {
    el.innerHTML = '<p class="debug-hint">暂无数据</p>';
    return;
  }

  el.innerHTML = Object.entries(data).map(([key, value]) => `
    <div class="debug-table-row">
      <span>${key}</span>
      <strong>${formatDebugValue(value)}</strong>
    </div>
  `).join('');
}

function appendDebugLog(message, type = 'info') {
  const log = $('#debugLog');
  if (!log) return;

  const row = document.createElement('div');
  row.className = `debug-log-row ${type}`;
  row.innerHTML = `<span>${formatTime(new Date())}</span><p>${message}</p>`;
  log.prepend(row);
}

function getActiveModelLoaded(model) {
  if (!model) return false;
  if (model.backend === 'sensevoice') return model.sensevoice_loaded;
  if (model.backend === 'caire') return model.caire_loaded;
  if (model.backend === 'local_cnn') return model.local_cnn_loaded;
  return model.fallback_backend === 'rule';
}

function getActiveModelId(model) {
  if (!model) return '--';
  if (model.backend === 'sensevoice') return model.sensevoice_model_id;
  if (model.backend === 'caire') return model.caire_model_id;
  if (model.backend === 'local_cnn') return 'models/emotion_cnn.pth';
  return 'rule-based';
}

async function initModelDebugPage() {
  setDebugText('#debugApiBase', API_BASE_URL);
  await loadDebugMicrophones(false);
  await loadModelDebugStatus();
  await Promise.all([
    loadTrainingCorpus(),
    loadTrainingJob(),
    loadTrainingModels(),
  ]);
}

async function loadDebugMicrophones(requestPermission = true) {
  const select = $('#debugMicSelect');
  if (!select || !navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;

  try {
    if (requestPermission && navigator.mediaDevices.getUserMedia) {
      const permissionStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      permissionStream.getTracks().forEach(track => track.stop());
    }

    const currentValue = select.value;
    const devices = await navigator.mediaDevices.enumerateDevices();
    const audioInputs = devices.filter(device => device.kind === 'audioinput');
    select.innerHTML = '<option value="">系统默认麦克风</option>' + audioInputs.map((device, index) => {
      const label = device.label || `麦克风 ${index + 1}`;
      return `<option value="${device.deviceId}">${label}</option>`;
    }).join('');

    if (currentValue && audioInputs.some(device => device.deviceId === currentValue)) {
      select.value = currentValue;
    }

    appendDebugLog(`麦克风设备：${audioInputs.map((device, index) => device.label || `麦克风 ${index + 1}`).join(' / ') || '未发现'}`);
  } catch (error) {
    appendDebugLog(`刷新麦克风列表失败：${error.message}`, 'error');
  }
}

async function loadModelDebugStatus() {
  try {
    const info = await api.getSystemInfo();
    const model = info.emotion_model || {};
    const loaded = getActiveModelLoaded(model);
    const calibratorLoaded = Boolean(model.tri_class_calibrator_loaded);
    const cudaText = model.torch_cuda_available
      ? `可用 ${model.torch_cuda_version || ''} ${model.cuda_device || ''}`.trim()
      : '不可用';

    setDebugText('#debugBackend', model.backend);
    setDebugText('#debugDevice', model.device);
    setDebugText('#debugCuda', cudaText);
    setDebugText('#debugLoaded', loaded ? '主模型已加载' : calibratorLoaded ? '校准模型已加载' : '未加载');
    setDebugText('#debugModelId', getActiveModelId(model));
    setDebugText('#debugCalibratorVersion', model.tri_class_calibrator_version || '未加载');
    setDebugBadge(
      '#modelDebugStatusBadge',
      loaded ? '主模型已加载' : calibratorLoaded ? '校准模型已加载' : '模型未加载',
      loaded || calibratorLoaded ? 'success' : 'warning',
    );

    if (model.sensevoice_load_error || model.caire_load_error) {
      appendDebugLog(`模型加载错误：${model.sensevoice_load_error || model.caire_load_error}`, 'error');
    } else {
      appendDebugLog(`模型状态刷新：${model.backend || 'unknown'} / ${loaded ? 'loaded' : 'not loaded'}`);
    }
  } catch (error) {
    setDebugBadge('#modelDebugStatusBadge', '后端不可用', 'danger');
    appendDebugLog(`读取后端状态失败：${error.message}`, 'error');
  }
}

async function preloadDebugModel() {
  setDebugBadge('#modelDebugStatusBadge', '加载中', 'warning');
  appendDebugLog('开始预加载情绪模型');

  try {
    const result = await api.preloadEmotionModel();
    const model = result.emotion_model || {};
    const loaded = getActiveModelLoaded(model);
    setDebugBadge('#modelDebugStatusBadge', loaded ? '模型已加载' : '加载失败', loaded ? 'success' : 'danger');
    appendDebugLog(`预加载完成：${model.backend || 'unknown'} / loaded=${result.loaded}`);
    await loadModelDebugStatus();
  } catch (error) {
    setDebugBadge('#modelDebugStatusBadge', '加载失败', 'danger');
    appendDebugLog(`预加载失败：${error.message}`, 'error');
  }
}

async function ensureModelDebugSession() {
  if (!state.user) {
    throw new Error('请先在 Web 页面创建用户或登录');
  }

  if (!state.user.families || state.user.families.length === 0) {
    const family = await api.createFamily('模型调试家庭');
    state.user = await api.getMe();
    localStorage.setItem('softerplease_user', JSON.stringify(state.user));
    appendDebugLog(`已创建调试家庭：${family.family_id || family.id || 'unknown'}`);
  }

  if (state.modelDebugSession && state.modelDebugSession.session_id) {
    return state.modelDebugSession;
  }

  const familyId = state.user.families[0].family_id;
  const deviceId = 'web-model-debug-' + Math.random().toString(36).slice(2, 10);
  state.modelDebugSession = await api.startSession(familyId, deviceId, 'web-model-debug');
  appendDebugLog(`已创建调试会话：${state.modelDebugSession.session_id}`);
  return state.modelDebugSession;
}

function updateDebugRecordTimer() {
  if (!debugRecordStartedAt) return;
  const seconds = Math.floor((Date.now() - debugRecordStartedAt) / 1000);
  const minutes = Math.floor(seconds / 60).toString().padStart(2, '0');
  const rest = (seconds % 60).toString().padStart(2, '0');
  setDebugText('#debugRecordTimer', `${minutes}:${rest}`);
}

async function startDebugRecording() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    alert('当前浏览器不支持麦克风录音，请使用 Chrome/Edge 并通过 localhost 打开页面');
    return;
  }

  try {
    await ensureModelDebugSession();
    debugRecordedChunks = [];
    debugRecordedBlob = null;
    debugWavBlob = null;
    debugPeakLevel = 0;
    debugRmsLevel = 0;
    updateDebugMicLevel(0);
    const selectedMic = $('#debugMicSelect')?.value || '';
    const audioConstraints = selectedMic
      ? { deviceId: { exact: selectedMic } }
      : true;
    debugStream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });

    debugAudioContext = new (window.AudioContext || window.webkitAudioContext)();
    debugCaptureSampleRate = debugAudioContext.sampleRate;
    debugAudioSource = debugAudioContext.createMediaStreamSource(debugStream);
    debugAnalyser = debugAudioContext.createAnalyser();
    debugAnalyser.fftSize = 2048;
    debugLevelData = new Float32Array(debugAnalyser.fftSize);
    debugAudioSource.connect(debugAnalyser);
    debugLevelInterval = setInterval(pollDebugMicLevel, 120);

    const mimeType = pickDebugRecordingMimeType();
    debugMediaRecorder = new MediaRecorder(debugStream, mimeType ? { mimeType } : undefined);
    debugMediaRecorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) {
        debugRecordedChunks.push(event.data);
      }
    };
    debugMediaRecorder.onstop = () => finalizeDebugRecording();
    debugMediaRecorder.start(250);
    debugRecordStartedAt = Date.now();
    debugRecordTimerInterval = setInterval(updateDebugRecordTimer, 250);
    updateDebugRecordTimer();

    $('#startDebugRecordBtn')?.classList.add('hidden');
    $('#stopDebugRecordBtn')?.classList.remove('hidden');
    $('#analyzeDebugRecordBtn')?.setAttribute('disabled', 'disabled');
    setDebugBadge('#debugRecordState', '录制中', 'warning');
    setDebugBadge('#debugResultState', '录音中', 'warning');
    const track = debugStream.getAudioTracks()[0];
    appendDebugLog(`开始录音：${track?.label || '默认麦克风'} / ${debugMediaRecorder.mimeType || 'browser-default'}，输入采样率 ${debugCaptureSampleRate} Hz`);
  } catch (error) {
    cleanupDebugRecording();
    appendDebugLog(`开始录音失败：${error.message}`, 'error');
    alert('开始录音失败: ' + error.message);
  }
}

function pickDebugRecordingMimeType() {
  if (!window.MediaRecorder) return '';
  const candidates = [
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/ogg;codecs=opus',
    'audio/mp4',
  ];
  return candidates.find(type => MediaRecorder.isTypeSupported(type)) || '';
}

function stopDebugRecording() {
  if (debugRecordTimerInterval) {
    clearInterval(debugRecordTimerInterval);
    debugRecordTimerInterval = null;
  }

  if (debugMediaRecorder && debugMediaRecorder.state !== 'inactive') {
    debugMediaRecorder.stop();
  } else {
    finalizeDebugRecording();
  }
}

async function finalizeDebugRecording() {
  cleanupDebugRecording();
  $('#startDebugRecordBtn')?.classList.remove('hidden');
  $('#stopDebugRecordBtn')?.classList.add('hidden');

  try {
    if (debugRecordedChunks.length === 0) {
      throw new Error('浏览器没有产出录音数据，请检查麦克风权限');
    }

    const type = debugMediaRecorder?.mimeType || debugRecordedChunks[0]?.type || 'audio/webm';
    debugRecordedBlob = new Blob(debugRecordedChunks, { type });
    if (debugRecordedBlob.size < 1024) {
      throw new Error(`录音文件过小（${debugRecordedBlob.size} bytes），请检查麦克风权限或输入设备`);
    }

    setDebugText('#debugAudioMeta', `原始录音：${type}，${(debugRecordedBlob.size / 1024).toFixed(1)} KB，正在转换 WAV`);
    const originalPlayer = $('#debugOriginalAudioPlayer');
    if (originalPlayer) {
      originalPlayer.src = URL.createObjectURL(debugRecordedBlob);
      originalPlayer.load();
    }

    debugWavBlob = await convertRecordedBlobToWav(debugRecordedBlob);
    if (debugPeakLevel < 0.005) {
      appendDebugLog('麦克风输入电平接近 0，这段录音很可能是静音。请检查浏览器麦克风权限和系统输入设备。', 'error');
    }

    const player = $('#debugAudioPlayer');
    if (player) {
      player.src = URL.createObjectURL(debugWavBlob);
      player.load();
    }

    const duration = await getDebugWavDuration(debugWavBlob);
    setDebugText('#debugAudioMeta', `原始录音：${type}，${(debugRecordedBlob.size / 1024).toFixed(1)} KB；提交/播放 WAV：${duration.toFixed(2)} 秒，${(debugWavBlob.size / 1024).toFixed(1)} KB / 16kHz mono；峰值 ${debugPeakLevel.toFixed(3)} / RMS ${debugRmsLevel.toFixed(3)}`);
    $('#analyzeDebugRecordBtn')?.removeAttribute('disabled');
    setDebugBadge('#debugRecordState', debugPeakLevel < 0.005 ? '近似静音' : '已停止', debugPeakLevel < 0.005 ? 'danger' : 'success');
    appendDebugLog(`录音停止：原始 ${debugRecordedBlob.size} bytes，WAV ${debugWavBlob.size} bytes，peak=${debugPeakLevel.toFixed(4)} rms=${debugRmsLevel.toFixed(4)}`);
    await analyzeDebugRecording();
  } catch (error) {
    setDebugBadge('#debugRecordState', '录音失败', 'danger');
    setDebugBadge('#debugResultState', '录音失败', 'danger');
    appendDebugLog(`录音失败：${error.message}`, 'error');
  }
}

function cleanupDebugRecording() {
  if (debugLevelInterval) {
    clearInterval(debugLevelInterval);
    debugLevelInterval = null;
  }

  if (debugRecordTimerInterval) {
    clearInterval(debugRecordTimerInterval);
    debugRecordTimerInterval = null;
  }

  if (debugAnalyser) {
    debugAnalyser.disconnect();
    debugAnalyser = null;
  }

  if (debugAudioSource) {
    debugAudioSource.disconnect();
    debugAudioSource = null;
  }

  if (debugAudioContext) {
    debugAudioContext.close().catch(() => {});
    debugAudioContext = null;
  }

  if (debugStream) {
    debugStream.getTracks().forEach(track => track.stop());
    debugStream = null;
  }
}

function pollDebugMicLevel() {
  if (!debugAnalyser || !debugLevelData) return;

  debugAnalyser.getFloatTimeDomainData(debugLevelData);
  let sumSquares = 0;
  let peak = 0;
  for (const sample of debugLevelData) {
    const abs = Math.abs(sample);
    if (abs > peak) peak = abs;
    sumSquares += sample * sample;
  }

  const rms = Math.sqrt(sumSquares / debugLevelData.length);
  debugPeakLevel = Math.max(debugPeakLevel, peak);
  debugRmsLevel = Math.max(debugRmsLevel, rms);
  updateDebugMicLevel(rms);
}

function updateDebugMicLevel(level) {
  const normalized = Math.max(0, Math.min(1, level * 8));
  const fill = $('#debugMicLevelFill');
  if (fill) {
    fill.style.width = `${(normalized * 100).toFixed(0)}%`;
  }

  const text = $('#debugMicLevelText');
  if (text) {
    text.textContent = level.toFixed(3);
  }
}

async function convertRecordedBlobToWav(blob) {
  const arrayBuffer = await blob.arrayBuffer();
  const context = new (window.AudioContext || window.webkitAudioContext)();
  const decoded = await context.decodeAudioData(arrayBuffer.slice(0));
  const sampleRate = decoded.sampleRate;
  const channelCount = decoded.numberOfChannels;
  const mixed = new Float32Array(decoded.length);

  for (let channel = 0; channel < channelCount; channel++) {
    const data = decoded.getChannelData(channel);
    for (let i = 0; i < data.length; i++) {
      mixed[i] += data[i] / channelCount;
    }
  }

  const resampled = resampleAudio(mixed, sampleRate, 16000);
  await context.close();
  return audioToWav(resampled, 16000);
}

async function getDebugWavDuration(blob) {
  const size = blob.size;
  const payloadBytes = Math.max(0, size - 44);
  return payloadBytes / (16000 * 2);
}

async function handleDebugAudioUpload(event) {
  const file = event.target.files?.[0];
  if (!file) return;

  try {
    await ensureModelDebugSession();
    debugWavBlob = null;
    setDebugBadge('#debugRecordState', '文件转换中', 'warning');
    setDebugBadge('#debugResultState', '文件转换中', 'warning');

    const originalPlayer = $('#debugOriginalAudioPlayer');
    if (originalPlayer) {
      originalPlayer.src = URL.createObjectURL(file);
      originalPlayer.load();
    }

    appendDebugLog(`选择上传音频：${file.name} / ${file.type || 'unknown'} / ${file.size} bytes`);
    setDebugText('#debugAudioMeta', `上传原始音频：${file.name}，${(file.size / 1024).toFixed(1)} KB，正在转换为 16kHz mono WAV`);
    debugWavBlob = await convertRecordedBlobToWav(file);
    const player = $('#debugAudioPlayer');
    if (player) {
      player.src = URL.createObjectURL(debugWavBlob);
      player.load();
    }

    setDebugText('#debugAudioMeta', `上传原始音频：${file.name}，${(file.size / 1024).toFixed(1)} KB；提交 WAV：${(debugWavBlob.size / 1024).toFixed(1)} KB / 16kHz mono`);
    $('#analyzeDebugRecordBtn')?.removeAttribute('disabled');
    setDebugBadge('#debugRecordState', '文件已就绪', 'success');
    await analyzeDebugRecording();
  } catch (error) {
    setDebugBadge('#debugRecordState', '上传失败', 'danger');
    setDebugBadge('#debugResultState', '上传失败', 'danger');
    appendDebugLog(`上传音频处理失败：${error.message}`, 'error');
    alert('上传音频处理失败: ' + error.message);
  } finally {
    event.target.value = '';
  }
}

function resampleAudio(audioData, sourceRate, targetRate) {
  if (sourceRate === targetRate) {
    return audioData;
  }

  const ratio = sourceRate / targetRate;
  const newLength = Math.max(1, Math.round(audioData.length / ratio));
  const result = new Float32Array(newLength);

  for (let i = 0; i < newLength; i++) {
    const sourceIndex = i * ratio;
    const left = Math.floor(sourceIndex);
    const right = Math.min(left + 1, audioData.length - 1);
    const weight = sourceIndex - left;
    result[i] = audioData[left] * (1 - weight) + audioData[right] * weight;
  }

  return result;
}

async function analyzeDebugRecording() {
  if (!debugWavBlob) {
    alert('请先录制或上传一段音频');
    return;
  }

  try {
    const session = await ensureModelDebugSession();
    const formData = new FormData();
    formData.append('audio', debugWavBlob, 'debug-recording.wav');
    formData.append('transcript', $('#debugTranscript')?.value || '');
    formData.append('speaker_id', $('#debugSpeakerId')?.value || 'web_debug_user');

    setDebugBadge('#debugResultState', '分析中', 'warning');
    appendDebugLog('提交音频到模型分析接口');

    const response = await fetch(`${API_BASE_URL}/v1/sessions/${session.session_id}/analyze`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${state.token}`,
      },
      body: formData,
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(errorText || `HTTP ${response.status}`);
    }

    const result = await response.json();
    renderDebugResult(result);
    setDebugBadge('#debugResultState', '分析完成', 'success');
    appendDebugLog(`分析完成：value=${result.emotion_value} level=${result.emotion_level} backend=${result.model_backend}`);
    await loadModelDebugStatus();
    await loadClientDebugAudio();
  } catch (error) {
    setDebugBadge('#debugResultState', '分析失败', 'danger');
    appendDebugLog(`分析失败：${error.message}`, 'error');
  }
}

function renderDebugResult(result) {
  setDebugText('#debugEmotionValue', result.emotion_value);
  setDebugText('#debugEmotionLevel', result.emotion_level);
  setDebugText('#debugResultBackend', result.model_backend);
  setDebugText('#debugConfidence', formatDebugValue(result.confidence));
  setDebugText('#debugAngerScore', formatDebugValue(result.anger_score));
  setDebugText('#debugSpeakerResult', `${result.speaker_id || '--'} (${formatDebugValue(result.speaker_confidence)})`);
  setDebugText('#debugRecognizedTranscript', result.transcript || '--');
  renderDebugTable('#debugRawEmotions', result.raw_emotions);
  renderDebugTable('#debugAcousticFeatures', result.acoustic_features);

  const jsonEl = $('#debugResultJson');
  if (jsonEl) {
    jsonEl.textContent = JSON.stringify(result, null, 2);
  }
}

async function loadTrainingCorpus() {
  const body = $('#corpusTableBody');
  if (!body) return;
  try {
    const data = await api.getTrainingCorpus();
    trainingCorpusItems = data.items || [];
    renderTrainingCorpusSummary(data.summary || {});
    renderTrainingCorpus();
  } catch (error) {
    body.innerHTML = `<tr><td colspan="6">读取语料失败：${escapeDebugHtml(error.message)}</td></tr>`;
    appendDebugLog(`读取训练语料失败：${error.message}`, 'error');
  }
}

function renderTrainingCorpusSummary(summary = {}) {
  setDebugText('#corpusTotal', summary.total ?? trainingCorpusItems.length);
  setDebugText('#corpusSelected', summary.selected ?? trainingCorpusItems.filter(item => item.selected).length);
  setDebugText('#corpusLabeled', summary.selected_labeled ?? trainingCorpusItems.filter(item => item.selected && item.label !== null && item.label !== undefined).length);
  setDebugText('#corpusSilent', summary.near_silent ?? trainingCorpusItems.filter(item => item.diagnostic?.near_silent).length);
}

function getVisibleTrainingCorpus() {
  const source = $('#corpusSourceFilter')?.value || 'all';
  const label = $('#corpusLabelFilter')?.value || 'all';
  const query = ($('#corpusSearchInput')?.value || '').trim().toLowerCase();
  return trainingCorpusItems.filter(item => {
    if (source !== 'all' && item.kind !== source) return false;
    if (label === 'unlabeled' && item.label !== null && item.label !== undefined) return false;
    if (!['all', 'unlabeled'].includes(label) && Number(item.label) !== Number(label)) return false;
    if (query) {
      const haystack = `${item.filename} ${item.transcript} ${item.source}`.toLowerCase();
      if (!haystack.includes(query)) return false;
    }
    return true;
  });
}

function emotionLabelText(label) {
  if (label === null || label === undefined || label === '') return '未标注';
  if (Number(label) === -1) return '-1 负向';
  if (Number(label) === 0) return '0 中性';
  if (Number(label) === 1) return '1 正向';
  return '未标注';
}

function renderTrainingCorpus() {
  const body = $('#corpusTableBody');
  if (!body) return;
  const items = getVisibleTrainingCorpus();
  if (items.length === 0) {
    body.innerHTML = '<tr><td colspan="6">当前筛选条件下没有语料。</td></tr>';
    return;
  }
  body.innerHTML = items.map(item => {
    const diagnostic = item.diagnostic || {};
    const audioUrl = `${API_BASE_URL}${item.audio_url}`;
    const labelButtons = [-1, 0, 1].map(label => `
      <button
        class="corpus-label-button ${item.label !== null && item.label !== undefined && Number(item.label) === label ? 'active' : ''}"
        data-corpus-label="${label}"
        data-corpus-id="${escapeDebugHtml(item.id)}"
        title="${emotionLabelText(label)}"
      >${label}</button>
    `).join('');
    return `
      <tr class="${diagnostic.near_silent ? 'corpus-row-silent' : ''}">
        <td>
          <input type="checkbox" data-corpus-select="${escapeDebugHtml(item.id)}" ${item.selected ? 'checked' : ''} />
        </td>
        <td><audio controls preload="metadata" src="${escapeDebugHtml(audioUrl)}"></audio></td>
        <td>
          <strong>${escapeDebugHtml(item.source)}</strong>
          <span>${escapeDebugHtml(item.filename)}</span>
        </td>
        <td>
          <textarea data-corpus-transcript="${escapeDebugHtml(item.id)}" rows="2">${escapeDebugHtml(item.transcript || '')}</textarea>
        </td>
        <td>
          <div class="corpus-label-control">${labelButtons}</div>
          <span>${escapeDebugHtml(emotionLabelText(item.label))}</span>
        </td>
        <td>
          <span>RMS ${formatDebugValue(Number(diagnostic.rms || 0))}</span>
          <span>峰值 ${formatDebugValue(Number(diagnostic.peak || 0))}</span>
          <span>${formatDebugValue(Number(diagnostic.duration || 0))} 秒</span>
          ${diagnostic.near_silent ? '<strong class="quality-danger">近似静音</strong>' : '<strong class="quality-ok">有效声音</strong>'}
        </td>
      </tr>
    `;
  }).join('');
}

async function updateTrainingCorpus(ids, changes, message) {
  if (!ids.length) return;
  try {
    const result = await api.updateTrainingCorpus(ids, changes);
    for (const item of trainingCorpusItems) {
      if (!ids.includes(item.id)) continue;
      Object.assign(item, changes);
    }
    renderTrainingCorpusSummary(result.summary || {});
    renderTrainingCorpus();
    if (message) appendDebugLog(message);
  } catch (error) {
    appendDebugLog(`更新语料失败：${error.message}`, 'error');
    await loadTrainingCorpus();
  }
}

async function startTraining() {
  const button = $('#startTrainingBtn');
  if (!button) return;
  button.disabled = true;
  try {
    const job = await api.startTrainingJob({
      version_name: $('#trainingVersionName')?.value.trim() || null,
      test_ratio: Number($('#trainingTestRatio')?.value || 0.2),
      activate_after_training: Boolean($('#activateAfterTraining')?.checked),
    });
    renderTrainingJob(job);
    scheduleTrainingPoll();
    appendDebugLog(`微调任务已启动：${job.version}`);
  } catch (error) {
    setDebugBadge('#trainingStatusBadge', '启动失败', 'danger');
    appendDebugLog(`启动微调失败：${error.message}`, 'error');
    button.disabled = false;
  }
}

function scheduleTrainingPoll() {
  clearTimeout(trainingPollTimer);
  trainingPollTimer = setTimeout(loadTrainingJob, 900);
}

async function loadTrainingJob() {
  try {
    const data = await api.getCurrentTrainingJob();
    renderTrainingJob(data.job);
    if (data.job && ['queued', 'running'].includes(data.job.status)) {
      scheduleTrainingPoll();
    }
  } catch (error) {
    appendDebugLog(`读取训练进度失败：${error.message}`, 'error');
  }
}

function renderTrainingJob(job) {
  const startButton = $('#startTrainingBtn');
  if (!job) {
    setDebugBadge('#trainingStatusBadge', '空闲');
    if (startButton) startButton.disabled = false;
    return;
  }
  const running = ['queued', 'running'].includes(job.status);
  const badgeType = job.status === 'completed' ? 'success' : job.status === 'failed' ? 'danger' : 'warning';
  setDebugBadge('#trainingStatusBadge', job.status, badgeType);
  setDebugText('#trainingProgressText', `${job.progress || 0}%`);
  setDebugText('#trainingStageText', job.message || job.stage);
  const fill = $('#trainingProgressFill');
  if (fill) fill.style.width = `${job.progress || 0}%`;
  if (startButton) startButton.disabled = running;
  const log = $('#trainingLog');
  if (log) {
    log.innerHTML = (job.logs || []).slice(-40).reverse().map(message => `
      <div class="debug-log-row"><span>${escapeDebugHtml(job.stage || '--')}</span><p>${escapeDebugHtml(message)}</p></div>
    `).join('') || '<p class="debug-hint">暂无训练日志。</p>';
  }
  const metrics = $('#trainingMetrics');
  if (metrics) metrics.textContent = JSON.stringify(job.metrics || { status: job.status, message: job.message }, null, 2);
  if (job.status === 'completed') {
    loadTrainingModels();
    loadModelDebugStatus();
  }
}

async function loadTrainingModels() {
  const select = $('#modelVersionSelect');
  const list = $('#modelVersionList');
  if (!select || !list) return;
  try {
    const data = await api.getTrainingModels();
    const items = data.items || [];
    select.innerHTML = items.length
      ? items.map(item => `<option value="${escapeDebugHtml(item.version)}">${escapeDebugHtml(item.version)}${item.active ? '（当前）' : ''}</option>`).join('')
      : '<option value="">暂无微调模型</option>';
    const active = items.find(item => item.active);
    if (active) select.value = active.version;
    list.innerHTML = items.length
      ? items.map(item => `
          <div class="model-version-row">
            <div>
              <strong>${escapeDebugHtml(item.version)}</strong>
              <span>${escapeDebugHtml(item.created_at ? new Date(item.created_at).toLocaleString('zh-CN') : '--')}</span>
            </div>
            <span>训练 ${escapeDebugHtml(item.metrics?.train_samples ?? '--')} / 测试 ${escapeDebugHtml(item.metrics?.test_samples ?? '--')}</span>
            <span>测试准确率 ${escapeDebugHtml(item.metrics?.test_accuracy === undefined ? '--' : Number(item.metrics.test_accuracy).toFixed(3))}</span>
            ${item.active ? '<strong class="quality-ok">当前加载</strong>' : ''}
          </div>
        `).join('')
      : '<p class="debug-hint">暂无微调模型版本。</p>';
  } catch (error) {
    list.innerHTML = `<p class="debug-hint">读取模型版本失败：${escapeDebugHtml(error.message)}</p>`;
  }
}

async function loadSelectedTrainingModel() {
  const version = $('#modelVersionSelect')?.value;
  if (!version) return;
  try {
    await api.loadTrainingModel(version);
    appendDebugLog(`已加载模型版本：${version}`);
    await Promise.all([loadTrainingModels(), loadModelDebugStatus()]);
  } catch (error) {
    appendDebugLog(`加载模型版本失败：${error.message}`, 'error');
  }
}

async function loadClientDebugAudio() {
  const container = $('#clientAudioList');
  if (!container) return;

  try {
    const data = await api.getDebugAudio(30);
    const items = data.items || [];
    if (items.length === 0) {
      container.innerHTML = '<p class="debug-hint">还没有客户端上传记录。请先在手机 App 录制并分析一次。</p>';
      return;
    }

    container.innerHTML = items.map(renderClientAudioItem).join('');
  } catch (error) {
    container.innerHTML = `<p class="debug-hint">读取客户端上传记录失败：${escapeDebugHtml(error.message)}</p>`;
    appendDebugLog(`读取客户端上传记录失败：${error.message}`, 'error');
  }
}

function renderClientAudioItem(item) {
  const result = item.result || {};
  const audioUrl = `${API_BASE_URL}${item.audio_url}`;
  const createdAt = item.created_at ? new Date(item.created_at).toLocaleString('zh-CN') : '--';
  const audioSize = item.audio_bytes ? `${(item.audio_bytes / 1024).toFixed(1)} KB` : '--';
  const duration = item.audio_duration_ms ? `${(item.audio_duration_ms / 1000).toFixed(2)} 秒` : '--';
  const rawTop = result.raw_emotions
    ? Object.entries(result.raw_emotions)
        .sort((a, b) => Number(b[1]) - Number(a[1]))
        .slice(0, 4)
        .map(([key, value]) => `${key} ${formatDebugValue(value)}`)
        .join(' / ')
    : '--';

  return `
    <article class="client-audio-item">
      <div class="client-audio-header">
        <div>
          <strong>${escapeDebugHtml(item.source || 'unknown')}</strong>
          <span>${escapeDebugHtml(createdAt)}</span>
        </div>
        <span class="status-badge">${escapeDebugHtml(result.model_backend || '--')}</span>
      </div>
      <audio controls src="${audioUrl}"></audio>
      <div class="client-audio-metrics">
        <div><span>情绪值</span><strong>${escapeDebugHtml(formatDebugValue(result.emotion_value))}</strong></div>
        <div><span>愤怒强度</span><strong>${escapeDebugHtml(result.emotion_level || '--')}</strong></div>
        <div><span>置信度</span><strong>${escapeDebugHtml(formatDebugValue(result.confidence))}</strong></div>
        <div><span>文件</span><strong>${escapeDebugHtml(audioSize)}</strong></div>
        <div><span>时长</span><strong>${escapeDebugHtml(duration)}</strong></div>
        <div><span>说话人</span><strong>${escapeDebugHtml(result.speaker_id || item.speaker_id || '--')}</strong></div>
      </div>
      <p class="debug-hint">Top: ${escapeDebugHtml(rawTop)}</p>
      ${item.transcript ? `<p class="debug-hint">文本：${escapeDebugHtml(item.transcript)}</p>` : ''}
      <div class="client-audio-labels">
        <span>人工标签：${item.human_label === undefined ? '未标注' : escapeDebugHtml(formatDebugValue(item.human_label))}</span>
        <button data-debug-record="${escapeDebugHtml(item.id)}" data-debug-label="-1" class="btn-small">-1 负向</button>
        <button data-debug-record="${escapeDebugHtml(item.id)}" data-debug-label="0" class="btn-small">0 中性</button>
        <button data-debug-record="${escapeDebugHtml(item.id)}" data-debug-label="1" class="btn-small">1 正向</button>
      </div>
      <details>
        <summary>完整结果 JSON</summary>
        <pre class="debug-json">${escapeDebugHtml(JSON.stringify(item, null, 2))}</pre>
      </details>
    </article>
  `;
}

function escapeDebugHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

// 事件监听
function initEventListeners() {
  // 登录
  $('#createUserBtn')?.addEventListener('click', () => {
    const nickname = $('#nicknameInput').value.trim();
    if (nickname) {
      auth.createUser(nickname);
    }
  });
  
  // 退出
  $('#logoutBtn')?.addEventListener('click', () => {
    auth.logout();
  });
  
  // 会话控制
  $('#startSessionBtn')?.addEventListener('click', startSession);
  $('#endSessionBtn')?.addEventListener('click', endSession);

  // 模型调试
  $('#refreshModelStatusBtn')?.addEventListener('click', loadModelDebugStatus);
  $('#preloadModelBtn')?.addEventListener('click', preloadDebugModel);
  $('#refreshDebugMicsBtn')?.addEventListener('click', () => loadDebugMicrophones(true));
  $('#startDebugRecordBtn')?.addEventListener('click', startDebugRecording);
  $('#stopDebugRecordBtn')?.addEventListener('click', stopDebugRecording);
  $('#analyzeDebugRecordBtn')?.addEventListener('click', analyzeDebugRecording);
  $('#debugAudioFile')?.addEventListener('change', handleDebugAudioUpload);
  $('#clearDebugLogBtn')?.addEventListener('click', () => {
    const log = $('#debugLog');
    if (log) log.innerHTML = '';
  });
  $('#refreshCorpusBtn')?.addEventListener('click', loadTrainingCorpus);
  $('#corpusSourceFilter')?.addEventListener('change', renderTrainingCorpus);
  $('#corpusLabelFilter')?.addEventListener('change', renderTrainingCorpus);
  $('#corpusSearchInput')?.addEventListener('input', renderTrainingCorpus);
  $('#selectVisibleCorpusBtn')?.addEventListener('click', () => {
    const ids = getVisibleTrainingCorpus().map(item => item.id);
    updateTrainingCorpus(ids, { selected: true }, `已勾选当前结果：${ids.length} 条`);
  });
  $('#clearVisibleCorpusBtn')?.addEventListener('click', () => {
    const ids = getVisibleTrainingCorpus().map(item => item.id);
    updateTrainingCorpus(ids, { selected: false }, `已取消当前结果：${ids.length} 条`);
  });
  $('#corpusTableBody')?.addEventListener('change', event => {
    const checkbox = event.target.closest('[data-corpus-select]');
    if (checkbox) {
      updateTrainingCorpus(
        [checkbox.dataset.corpusSelect],
        { selected: checkbox.checked },
        `${checkbox.checked ? '勾选' : '取消'}语料：${checkbox.dataset.corpusSelect}`,
      );
      return;
    }
    const transcript = event.target.closest('[data-corpus-transcript]');
    if (transcript) {
      updateTrainingCorpus(
        [transcript.dataset.corpusTranscript],
        { transcript: transcript.value.trim() },
        `已更新文本：${transcript.dataset.corpusTranscript}`,
      );
    }
  });
  $('#corpusTableBody')?.addEventListener('click', event => {
    const button = event.target.closest('[data-corpus-id][data-corpus-label]');
    if (!button) return;
    updateTrainingCorpus(
      [button.dataset.corpusId],
      { label: Number(button.dataset.corpusLabel), selected: true },
      `人工标注：${button.dataset.corpusId} -> ${button.dataset.corpusLabel}`,
    );
  });
  $('#startTrainingBtn')?.addEventListener('click', startTraining);
  $('#refreshModelVersionsBtn')?.addEventListener('click', loadTrainingModels);
  $('#loadModelVersionBtn')?.addEventListener('click', loadSelectedTrainingModel);
  
  // 模拟控制
  $('#simAngerScore')?.addEventListener('input', (e) => {
    $('#simAngerValue').textContent = e.target.value;
  });
  
  $('#sendSimBtn')?.addEventListener('click', () => {
    if (!state.currentSession) {
      alert('请先开始会话');
      return;
    }
    
    const speakerId = $('#simSpeaker').value;
    const angerScore = parseFloat($('#simAngerScore').value);
    const transcript = $('#simTranscript').value;
    
    ws.analyze(state.currentSession.session_id, speakerId, angerScore, transcript);
  });
  
  // 反馈操作
  $('#acceptFeedbackBtn')?.addEventListener('click', () => {
    if (state.currentFeedbackToken) {
      ws.feedbackAction(state.currentFeedbackToken, 'accepted');
    }
  });
  
  $('#ignoreFeedbackBtn')?.addEventListener('click', () => {
    if (state.currentFeedbackToken) {
      ws.feedbackAction(state.currentFeedbackToken, 'ignored');
    }
  });
  
  // 创建目标
  $('#createGoalBtn')?.addEventListener('click', () => {
    $('#createGoalModal').classList.remove('hidden');
  });
  
  $('#cancelGoalBtn')?.addEventListener('click', () => {
    $('#createGoalModal').classList.add('hidden');
  });
  
  $('#createGoalForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    
    if (!state.user || !state.user.families || state.user.families.length === 0) return;
    
    const goalData = {
      goal_type: $('#goalType').value,
      title: $('#goalTitle').value,
      description: $('#goalDescription').value,
      target_value: parseFloat($('#goalTarget').value),
      unit: $('#goalUnit').value,
      start_date: $('#goalStartDate').value,
      end_date: $('#goalEndDate').value,
    };
    
    try {
      await api.createGoal(state.user.families[0].family_id, goalData);
      $('#createGoalModal').classList.add('hidden');
      loadGoalsData();
    } catch (error) {
      alert('创建目标失败: ' + error.message);
    }
  });
  
  // 复制邀请码
  $('#copyInviteCodeBtn')?.addEventListener('click', () => {
    const code = $('#familyInviteCode').textContent;
    navigator.clipboard.writeText(code).then(() => {
      alert('邀请码已复制');
    });
  });
  
  // 日期选择器
  $('#dashboardDate')?.addEventListener('change', () => {
    loadDashboardData();
  });
}

// 初始化
async function init() {
  // 设置默认日期
  const today = new Date().toISOString().split('T')[0];
  const dateInput = $('#dashboardDate');
  if (dateInput) {
    dateInput.value = today;
  }
  
  const goalStartDate = $('#goalStartDate');
  const goalEndDate = $('#goalEndDate');
  if (goalStartDate && goalEndDate) {
    goalStartDate.value = today;
    const nextMonth = new Date();
    nextMonth.setMonth(nextMonth.getMonth() + 1);
    goalEndDate.value = nextMonth.toISOString().split('T')[0];
  }
  
  // 初始化事件监听
  initEventListeners();
  navigation.init();
  
  // 检查登录状态
  await auth.init();
}

// 启动应用
document.addEventListener('DOMContentLoaded', init);
