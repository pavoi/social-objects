/**
 * ViewerChart Hook
 * Renders a Chart.js line chart for viewer count time-series data.
 * Supports optional GMV data on a secondary Y-axis.
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
    const hasGmv = data.hasGmv || false

    // Get theme from document (dark or light)
    const isDark = document.documentElement.classList.contains('dark')
    const textColor = isDark ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.7)'
    const gridColor = isDark ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'

    // Build scales config - add y1 axis for GMV if present
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
          maxTicksLimit: 8,
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
          text: 'Viewers',
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
            display: false,
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
                return `${context.parsed.y.toLocaleString()} viewers`
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
  },

  updated() {
    const data = JSON.parse(this.el.dataset.chartData)

    // Need to recreate chart if GMV status changed
    const currentHasGmv = this.chart.options.scales.y1 !== undefined
    const newHasGmv = data.hasGmv || false

    if (currentHasGmv !== newHasGmv) {
      // Destroy and recreate to update axes
      this.chart.destroy()
      this.mounted()
    } else {
      this.chart.data = data
      this.chart.update('none')
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}
