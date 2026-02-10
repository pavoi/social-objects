/**
 * HourlyPerformanceChart Hook
 * Renders a Chart.js line chart for hourly performance data.
 * Supports dual Y-axes: GMV (left) and Visitors (right).
 *
 * Chart.js is lazy-loaded when this hook mounts to reduce main bundle size.
 *
 * Usage in HEEx:
 *   <canvas
 *     id="hourly-performance-chart"
 *     phx-hook="HourlyPerformanceChart"
 *     data-chart-data={Jason.encode!(@hourly_chart_data)}
 *   />
 */

// Lazy-loaded Chart.js (shared across chart hooks via module cache)
let Chart = null

async function loadChartJS() {
  if (Chart) return Chart
  const module = await import('chart.js/auto')
  Chart = module.default
  return Chart
}

export default {
  async mounted() {
    await loadChartJS()
    this.currentData = this.el.dataset.chartData
    this.renderChart()
  },

  updated() {
    const newData = this.el.dataset.chartData
    if (newData === this.currentData) {
      return
    }
    this.currentData = newData

    if (this.chart) {
      this.chart.destroy()
    }
    this.renderChart()
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  },

  renderChart() {
    const ctx = this.el.getContext('2d')

    let data
    try {
      data = JSON.parse(this.currentData)
    } catch (e) {
      console.error('HourlyPerformanceChart: Failed to parse chart data', e)
      return
    }

    // Handle empty data
    if (!data || !data.labels || data.labels.length === 0) {
      return
    }

    const isDark = document.documentElement.classList.contains('dark')
    const textColor = isDark ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.7)'
    const gridColor = isDark ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'
    const hasGmv = data.hasGmv || false

    // Build scales config
    const scales = {
      x: {
        display: true,
        grid: {
          display: false,
        },
        ticks: {
          color: textColor,
          maxRotation: 0,
          autoSkip: true,
          maxTicksLimit: 12,
        }
      },
      y: {
        display: true,
        beginAtZero: true,
        position: 'left',
        grid: {
          color: gridColor,
        },
        ticks: {
          color: 'rgb(59, 130, 246)',
          callback: function(value) {
            return value.toLocaleString()
          }
        },
        title: {
          display: hasGmv,
          text: 'Visitors',
          color: 'rgb(59, 130, 246)',
        }
      }
    }

    // Add GMV axis if data is present
    if (hasGmv) {
      scales.y1 = {
        display: true,
        beginAtZero: true,
        position: 'right',
        grid: {
          drawOnChartArea: false,
        },
        ticks: {
          color: 'rgb(34, 197, 94)',
          callback: function(value) {
            if (value >= 1000) {
              return '$' + (value / 1000).toFixed(1) + 'k'
            }
            return '$' + value.toLocaleString()
          }
        },
        title: {
          display: true,
          text: 'GMV',
          color: 'rgb(34, 197, 94)',
        }
      }
    }

    this.chart = new Chart(ctx, {
      type: 'line',
      data: data,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
          mode: 'index',
          intersect: false,
        },
        plugins: {
          legend: {
            display: true,
            position: 'top',
            labels: {
              color: textColor,
              usePointStyle: true,
              pointStyle: 'line',
              padding: 16,
            }
          },
          tooltip: {
            backgroundColor: isDark ? 'rgba(0, 0, 0, 0.8)' : 'rgba(255, 255, 255, 0.9)',
            titleColor: isDark ? '#fff' : '#000',
            bodyColor: isDark ? '#fff' : '#000',
            borderColor: isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(0, 0, 0, 0.1)',
            borderWidth: 1,
            padding: 12,
            displayColors: true,
            callbacks: {
              label: function(context) {
                if (context.dataset.label === 'GMV') {
                  const value = context.parsed.y
                  if (value >= 1000) {
                    return `GMV: $${(value / 1000).toFixed(1)}k`
                  }
                  return `GMV: $${value.toLocaleString()}`
                }
                return `${context.dataset.label}: ${context.parsed.y.toLocaleString()}`
              }
            }
          }
        },
        scales: scales,
        elements: {
          point: {
            radius: 0,
            hoverRadius: 5,
          }
        }
      }
    })
  }
}
