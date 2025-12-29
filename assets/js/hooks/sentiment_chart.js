/**
 * SentimentChart Hook
 * Renders a Chart.js doughnut chart for sentiment breakdown.
 *
 * Usage in HEEx:
 *   <canvas
 *     id="sentiment-chart"
 *     phx-hook="SentimentChart"
 *     data-chart-data={Jason.encode!(@sentiment_chart_data)}
 *   />
 *
 * Expected data format:
 *   %{
 *     labels: ["Positive", "Neutral", "Negative"],
 *     data: [42, 45, 13],
 *     colors: ["rgb(34, 197, 94)", "rgb(156, 163, 175)", "rgb(239, 68, 68)"]
 *   }
 */
import Chart from 'chart.js/auto'

export default {
  mounted() {
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
      console.error('SentimentChart: Failed to parse chart data', e)
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
                const total = context.dataset.data.reduce((a, b) => a + b, 0)
                const percent = total > 0 ? Math.round((context.parsed / total) * 100) : 0
                return `${context.label}: ${percent}%`
              }
            }
          }
        }
      }
    })
  }
}
