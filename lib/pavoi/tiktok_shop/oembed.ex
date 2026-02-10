defmodule Pavoi.TiktokShop.OEmbed do
  @moduledoc """
  Fetches TikTok video metadata via the oEmbed API.

  Used to retrieve thumbnail URLs for video embeds.
  See: https://developers.tiktok.com/doc/embed-videos
  """

  @oembed_url "https://www.tiktok.com/oembed"
  @timeout_ms 10_000

  @doc """
  Fetches oEmbed data for a TikTok video URL.

  Returns `{:ok, %{thumbnail_url: url}}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> OEmbed.fetch("https://www.tiktok.com/@user/video/123")
      {:ok, %{thumbnail_url: "https://..."}}

      iex> OEmbed.fetch("https://www.tiktok.com/@user/video/invalid")
      {:error, :not_found}
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(video_url) when is_binary(video_url) do
    case Req.get(@oembed_url, params: [url: video_url], receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, parse_response(body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 400}} ->
        {:error, :invalid_url}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch(_), do: {:error, :invalid_url}

  defp parse_response(body) do
    %{
      thumbnail_url: body["thumbnail_url"],
      thumbnail_width: body["thumbnail_width"],
      thumbnail_height: body["thumbnail_height"],
      author_name: body["author_name"],
      title: body["title"]
    }
  end
end
