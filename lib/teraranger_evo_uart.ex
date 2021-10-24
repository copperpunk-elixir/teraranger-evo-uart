defmodule TerarangerEvoUart do
  use Bitwise
  require Logger
  require Crc

  @start_byte 84
  defstruct start_byte_found: false, remaining_buffer: [], range_ready: false, range: nil

  @spec new() :: struct()
  def new() do
    %TerarangerEvoUart{}
  end

  @spec check_for_new_range(struct(), list()) :: tuple()
  def check_for_new_range(evo, data) do
    evo = parse_data(evo, data)

    if evo.range_ready do
      {evo, evo.range}
    else
      {evo, nil}
    end
  end

  @spec parse_data(struct(), list()) :: map()
  def parse_data(evo, entire_buffer) do
    {valid_buffer, start_byte_found} =
      if !evo.start_byte_found do
        # A start byte has not been found yet. Search for it
        start_byte_index = Enum.find_index(entire_buffer, fn x -> x == @start_byte end)

        if start_byte_index == nil do
          # No start byte in the entire buffer, throw it all away
          {[], false}
        else
          # The buffer contains a start byte
          # Throw out everything before the start byte
          {_removed, valid_buffer} = Enum.split(entire_buffer, start_byte_index)
          {valid_buffer, true}
        end
      else
        # There is a valid start byte leftover from the last read
        {entire_buffer, true}
      end

    if start_byte_found do
      # The valid buffer should contain only the bytes after (and including) the start byte
      crc_calculation_buffer_and_remaining = valid_buffer

      {payload_buffer, crc_and_remaining_buffer} =
        Enum.split(crc_calculation_buffer_and_remaining, 3)

      # This could be a good message
      # The CRC is contained in the byte immediately following the payload
      {evo, parse_again} =
        unless Enum.empty?(crc_and_remaining_buffer) do
          crc_calc_value = calculate_checksum(payload_buffer)

          if crc_calc_value == Enum.at(crc_and_remaining_buffer, 0) do
            # Good Checksum, drop entire message before we parse the next time
            # We can leave the CRC bytes attached to the end of the payload buffer, because we know the length
            # The remaining_buffer is everything after the CRC bytes
            remaining_buffer = Enum.drop(crc_and_remaining_buffer, 1)
            {range, valid} = parse_good_message(Enum.drop(payload_buffer, 1))
            # Logger.debug("range: #{range}/#{valid}")
            evo = %{
              evo
              | remaining_buffer: remaining_buffer,
                start_byte_found: false,
                range: range,
                range_ready: valid
            }

            {evo, true}
          else
            # Bad checksum, which doesn't mean we lost some data
            # It could just mean that our "start byte" was just a data byte, so only
            # Drop the start byte before we parse next
            remaining_buffer = Enum.drop(valid_buffer, 1)
            evo = %{evo | remaining_buffer: remaining_buffer, start_byte_found: false}
            {evo, true}
          end
        else
          # We have not received enough data to parse a complete message
          # The next loop should try again with the same start_byte
          evo = %{evo | remaining_buffer: valid_buffer, start_byte_found: true}
          {evo, false}
        end

      if parse_again do
        parse_data(evo, evo.remaining_buffer)
      else
        evo
      end
    else
      %{evo | start_byte_found: false}
    end
  end

  @spec calculate_checksum(list()) :: integer()
  def calculate_checksum(buffer) do
    crc = 0

    Enum.reduce(Enum.take(buffer, 3), 0, fn x, acc ->
      i = Bitwise.^^^(acc, x) |> Bitwise.&&&(0xFF)

      Bitwise.<<<(crc, 8)
      |> Bitwise.^^^(Enum.at(Crc.crc_table(), i))
      |> Bitwise.&&&(0xFF)
    end)
  end

  @spec parse_good_message(list()) :: {integer(), boolean()}
  def parse_good_message(buffer) do
    # Logger.debug("payload buffer: #{inspect(buffer)}")
    range = Bitwise.<<<(Enum.at(buffer, 0), 8) + Enum.at(buffer, 1)

    if range == 0xFFFF do
      {0, false}
    else
      {range * 0.001, true}
    end
  end

  @spec clear(struct()) :: struct()
  def clear(evo) do
    %{evo | range_ready: false}
  end

  @spec create_message_for_range_mm(integer()) :: list()
  def create_message_for_range_mm(range) do
    {msb, lsb} =
      if range < 60000 do
        msb = Bitwise.>>>(range, 8)
        lsb = Bitwise.&&&(range, 0xFF)
        {msb, lsb}
      else
        {0xFF, 0xFF}
      end

    buffer = [@start_byte, msb, lsb]
    crc = calculate_checksum(buffer)
    buffer ++ [crc]
  end

  @spec create_message_for_range_m(float()) :: list()
  def create_message_for_range_m(range) do
    (range * 1000) |> round() |> create_message_for_range_mm()
  end
end
