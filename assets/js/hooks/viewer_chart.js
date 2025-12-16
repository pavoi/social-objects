/**
 * ViewerChart Hook
 * Renders a Chart.js line chart for viewer count time-series data.
 *
 * Usage in HEEx:
 *   <canvas
 *     id="viewer-chart"
 *     phx-hook="ViewerChart"
 *     data-chart-data={Jason.encode!(@chart_data)}
 *   />
 */
import Chart from 'chart.js/auto'

export default {
  mounted() {
    const ctx = this.el.getContext('2d')
    const data = JSON.parse(this.el.dataset.chartData)

    // Get theme from document (dark or light)
    const isDark = document.documentElement.classList.contains('dark')
    const textColor = isDark ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.7)'
    const gridColor = isDark ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'

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
            display: false,
          },
          tooltip: {
            backgroundColor: isDark ? 'rgba(0, 0, 0, 0.8)' : 'rgba(255, 255, 255, 0.9)',
            titleColor: isDark ? '#fff' : '#000',
            bodyColor: isDark ? '#fff' : '#000',
            borderColor: isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(0, 0, 0, 0.1)',
            borderWidth: 1,
            padding: 12,
            displayColors: false,
            callbacks: {
              label: function(context) {
                return `${context.parsed.y.toLocaleString()} viewers`
              }
            }
          }
        },
        scales: {
          x: {
            display: true,
            grid: {
              display: false,
            },
            ticks: {
              color: textColor,
              maxRotation: 0,
              autoSkip: true,
              maxTicksLimit: 8,
            }
          },
          y: {
            display: true,
            beginAtZero: true,
            grid: {
              color: gridColor,
            },
            ticks: {
              color: textColor,
              callback: function(value) {
                return value.toLocaleString()
              }
            }
          }
        },
        elements: {
          point: {
            radius: 0,
            hoverRadius: 5,
          }
        }
      }
    })
  },

  updated() {
    const data = JSON.parse(this.el.dataset.chartData)
    this.chart.data = data
    this.chart.update('none') // 'none' disables animations for smoother updates
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}
