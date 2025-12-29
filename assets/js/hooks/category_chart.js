/**
 * CategoryChart Hook
 * Renders a Chart.js horizontal bar chart for category breakdown.
 *
 * Usage in HEEx:
 *   <canvas
 *     id="category-chart"
 *     phx-hook="CategoryChart"
 *     data-chart-data={Jason.encode!(@category_chart_data)}
 *   />
 *
 * Expected data format:
 *   %{
 *     labels: ["Praise", "Questions", ...],
 *     data: [156, 89, ...],
 *     colors: ["rgb(34, 197, 94)", ...]
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
      console.error('CategoryChart: Failed to parse chart data', e)
      return
    }

    // Handle empty data
    if (!chartData || !chartData.labels || chartData.labels.length === 0) {
      return
    }

    const isDark = document.documentElement.classList.contains('dark')
    const textColor = isDark ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.7)'
    const gridColor = isDark ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'

    this.chart = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: chartData.labels,
        datasets: [{
          data: chartData.data,
          backgroundColor: chartData.colors,
          borderRadius: 4,
          barThickness: 24
        }]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: {
            display: false
          },
          tooltip: {
            backgroundColor: isDark ? 'rgba(0, 0, 0, 0.8)' : 'rgba(255, 255, 255, 0.9)',
            titleColor: isDark ? '#fff' : '#000',
            bodyColor: isDark ? '#fff' : '#000',
            borderColor: isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(0, 0, 0, 0.1)',
            borderWidth: 1,
            callbacks: {
              label: (context) => {
                return `${context.raw.toLocaleString()} comments`
              }
            }
          }
        },
        scales: {
          x: {
            display: true,
            beginAtZero: true,
            grid: { color: gridColor },
            ticks: { color: textColor }
          },
          y: {
            display: true,
            grid: { display: false },
            ticks: { color: textColor }
          }
        }
      }
    })
  }
}
