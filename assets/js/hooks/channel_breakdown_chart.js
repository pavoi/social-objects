/**
 * ChannelBreakdownChart Hook
 * Renders a Chart.js doughnut chart for GMV channel breakdown.
 *
 * Chart.js is lazy-loaded when this hook mounts to reduce main bundle size.
 *
 * Usage in HEEx:
 *   <canvas
 *     id="channel-breakdown-chart"
 *     phx-hook="ChannelBreakdownChart"
 *     data-chart-data={Jason.encode!(@channel_chart_data)}
 *   />
 *
 * Expected data format:
 *   %{
 *     labels: ["LIVE", "Video", "Product Card"],
 *     data: [180901.17, 983023.21, 624066.44],
 *     colors: ["rgb(239, 68, 68)", "rgb(59, 130, 246)", "rgb(34, 197, 94)"]
 *   }
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
    // Only re-render if chart data actually changed
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

    let chartData
    try {
      chartData = JSON.parse(this.currentData)
    } catch (e) {
      console.error('ChannelBreakdownChart: Failed to parse chart data', e)
      return
    }

    // Handle empty data
    if (!chartData || !chartData.labels || chartData.labels.length === 0) {
      return
    }

    const isDark = document.documentElement.classList.contains('dark')

    this.chart = new Chart(ctx, {
      type: 'doughnut',
      data: {
        labels: chartData.labels,
        datasets: [{
          data: chartData.data,
          backgroundColor: chartData.colors,
          borderWidth: 0,
          hoverOffset: 4
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        cutout: '60%',
        plugins: {
          legend: {
            position: 'bottom',
            labels: {
              color: isDark ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.7)',
              padding: 16,
              usePointStyle: true,
              pointStyle: 'circle'
            }
          },
          tooltip: {
            backgroundColor: isDark ? 'rgba(0, 0, 0, 0.8)' : 'rgba(255, 255, 255, 0.9)',
            titleColor: isDark ? '#fff' : '#000',
            bodyColor: isDark ? '#fff' : '#000',
            borderColor: isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(0, 0, 0, 0.1)',
            borderWidth: 1,
            callbacks: {
              label: (context) => {
                const value = context.parsed
                const total = context.dataset.data.reduce((a, b) => a + b, 0)
                const percent = total > 0 ? Math.round((value / total) * 100) : 0
                const formatted = value >= 1000
                  ? '$' + (value / 1000).toFixed(1) + 'K'
                  : '$' + value.toFixed(2)
                return `${context.label}: ${formatted} (${percent}%)`
              }
            }
          }
        }
      }
    })
  }
}
