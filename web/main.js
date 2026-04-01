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
      
      state.user = { ...user, ...authData.user };
      state.token = authData.access_token;
      
      // 保存到本地存储
      localStorage.setItem('softerplease_user', JSON.stringify(state.user));
      localStorage.setItem('softerplease_token', state.token);
      
      // 创建默认家庭
      const family = await api.createFamily('我的家庭');
      state.currentFamily = family;
      
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

// 会话控制
async function startSession() {
  if (!state.user || !state.user.families || state.user.families.length === 0) {
    alert('请先创建或加入家庭');
    return;
  }
  
  const familyId = state.user.families[0].family_id;
  const deviceId = 'web-' + Math.random().toString(36).substr(2, 9);
  
  try {
    const session = await api.startSession(familyId, deviceId, 'web');
    state.currentSession = session;
    
    $('#startSessionBtn').classList.add('hidden');
    $('#pauseSessionBtn').classList.remove('hidden');
    $('#endSessionBtn').classList.remove('hidden');
    
    api.trackEvent('session_started', { family_id: familyId });
  } catch (error) {
    alert('开始会话失败: ' + error.message);
  }
}

async function endSession() {
  if (!state.currentSession) return;
  
  try {
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
