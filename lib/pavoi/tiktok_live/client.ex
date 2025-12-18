defmodule Pavoi.TiktokLive.Client do
  @moduledoc """
  HTTP client for checking TikTok live stream status.

  This module handles:
  - Checking if a user is currently live
  - Fetching room information (room_id, viewer count, etc.)

  Note: TikTok does not provide an official API for live stream data.
  This implementation scrapes TikTok's live page to detect live status.
  The actual WebSocket connection is handled by Euler Stream's hosted service.
  """

  require Logger

  @tiktok_base_url "https://www.tiktok.com"

  # User agent to mimic a real browser
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  @doc """
  Checks if a TikTok user is currently live.

  Returns `{:ok, true}` if live, `{:ok, false}` if not live,
  or `{:error, reason}` on failure.

  ## Examples

      iex> TiktokLive.Client.live?("pavoi")
      {:ok, true}

  """
  def live?(unique_id) do
    case fetch_room_info(unique_id) do
      {:ok, %{is_live: is_live}} -> {:ok, is_live}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches room information for a TikTok live stream.

  Returns room_id, live status, title, viewer count, and other metadata.

  ## Examples

      iex> TiktokLive.Client.fetch_room_info("pavoi")
      {:ok, %{
        room_id: "7123456789",
        is_live: true,
        title: "Live stream title",
        viewer_count: 1234,
        raw_data: %{...}
      }}

  """
  def fetch_room_info(unique_id) do
    unique_id = normalize_unique_id(unique_id)
    url = "#{@tiktok_base_url}/@#{unique_id}/live"

    Logger.debug("Fetching room info for @#{unique_id}")

    case Req.get(url, headers: request_headers(), redirect: false) do
      {:ok, %{status: 200, body: body}} ->
        parse_room_info_from_html(body, unique_id)

      {:ok, %{status: status}} ->
        Logger.warning("TikTok returned status #{status} for @#{unique_id}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Failed to fetch room info: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp parse_room_info_from_html(html, unique_id) do
    # TikTok embeds room data in a SIGI_STATE script tag as JSON
    # We look for patterns like "roomId":"123456" or "room_id":"123456"
    with {:ok, room_id} <- extract_room_id(html),
         {:ok, is_live} <- extract_live_status(html) do
      room_info = %{
        room_id: room_id,
        unique_id: unique_id,
        is_live: is_live,
        title: extract_title(html),
        viewer_count: extract_viewer_count(html),
        raw_data: %{}
      }

      {:ok, room_info}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_room_id(html) do
    # Try multiple patterns as TikTok's HTML structure varies
    patterns = [
      # SIGI_STATE JSON pattern
      ~r/"roomId"\s*:\s*"(\d+)"/,
      ~r/"room_id"\s*:\s*"(\d+)"/,
      # Meta tag pattern
      ~r/room_id=(\d+)/,
      # LiveRoom data pattern
      ~r/"LiveRoom"[^}]*"id"\s*:\s*"(\d+)"/
    ]

    result =
      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, html) do
          [_, room_id] -> room_id
          _ -> nil
        end
      end)

    case result do
      nil -> {:error, :room_id_not_found}
      room_id -> {:ok, room_id}
    end
  end

  defp extract_live_status(html) do
    # Require positive evidence of live status to avoid false positives.
    # TikTok can return a 200 page with room_id even when not live (from previous streams).
    cond do
      String.contains?(html, "\"isLive\":true") -> {:ok, true}
      String.contains?(html, "\"liveRoomMode\":") -> {:ok, true}
      String.contains?(html, "\"status\":4") -> {:ok, true}
      # No positive live indicators found - user is not live
      true -> {:ok, false}
    end
  end

  defp extract_title(html) do
    case Regex.run(~r/"title"\s*:\s*"([^"]*)"/, html) do
      [_, title] -> title
      _ -> nil
    end
  end

  defp extract_viewer_count(html) do
    case Regex.run(~r/"viewerCount"\s*:\s*(\d+)/, html) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end

  defp normalize_unique_id(unique_id) do
    unique_id
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp request_headers do
    [
      {"user-agent", @user_agent},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end
end
