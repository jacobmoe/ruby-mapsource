module MapSource
  class InvalidFormatError < StandardError; end
  class UnsupportedVersionError < StandardError; end

  # Public: Parses GDB files and extracts waypoints, tracks and routes.
  #
  # Examples:
  #
  #   reader = MapSource::Reader.new(open('around_the_world.gdb'))
  #   reader.waypoints
  #   # => [MapSource::Waypoint<...>, ...]
  class Reader
    # Public: Range of format versions supported.
    SUPPORTED_VERSIONS = (1..3)

    attr_reader :header, :waypoints

    # Public: Creates a Reader.
    #
    # gdb - An IO object pointing to a GDB.
    def initialize(gdb)
      @gdb = gdb
      @header = read_header

      @parsed = false
    end

    # Public: Read waypoints from file.
    #
    # Returns an Array of waypoints.
    def waypoints
      read_data
      @waypoints
    end

    # Public: Reads tracks from file.
    #
    # Returns an Array of tracks.
    def tracks
      read_data
      @tracks
    end

    private
    # Reads data from the GDB file and sets Reader's internal state.
    #
    # Returns nothing.
    def read_data
      return if @parsed

      @waypoints = []
      @tracks = []

      while true
        len = @gdb.read(4).unpack('l').shift
        record = @gdb.read(len + 1)

        case record
        when /^W/
          @waypoints << read_waypoint(record)
        when /^T/
          @tracks << read_track(record)
        when /^V/
          break
        else
        end
      end

      @parsed = true
    end

    # Converts coordinates in semicircles to degrees.
    #
    # v - coordinate as semicircle
    #
    # Returns coordinate in degrees.
    def semicircle_to_degrees(v)
      (v.to_f / (1 << 31)) * 180.0
    end

    # Reads a waypoint record from the GDB.
    #
    # record - a binary string containing waypoint data.
    #
    # Returns waypoint.
    def read_waypoint(record)
      io = StringIO.new(record)

      read_char io
      shortname = read_string(io)
      wptclass = read_int(io)

      read_string(io)
      io.read 22 # skip 22 bytes

      lat = semicircle_to_degrees(read_int(io))
      lon = semicircle_to_degrees(read_int(io))

      wpt = Waypoint.new(lat, lon)
      wpt.shortname = shortname

      if read_boolean(io)
        alt = read_double(io)

        wpt.altitude = alt if alt < 1.0e24
      end

      wpt.notes = read_string(io)
      wpt.proximity = read_double(io) if read_boolean(io)

      read_int io # display
      read_int io # color, not implemented

      wpt.icon = read_int(io)
      wpt.city = read_string(io)
      wpt.state = read_string(io)
      wpt.facility = read_string(io)

      read_meaningless_chars io, 1

      wpt.depth = read_double(io) if read_boolean(io)

      if header.version <= 2
        read_meaningless_chars 2
        wptflag = read_boolean(io)

        read_meaningless_chars (waypt_flag ? 2 : 3)
        read_string io # undocumented and unused string

        wpt.add_url read_string(io)
        if wptclass != 0
          # It's a description, not an URL. Remove from URL list and set it.
          wpt.description = wpt.urls.shift
        end
      else
        wptflag = 0

        wpt.address = read_string(io)

        read_meaningless_chars io, 5 # not sure if they are in fact meaningless
        wpt.description = read_string(io)

        url_count = read_int(io)
        url_count.times do
          url = read_string(io)
          wpt.add_url(url) if url
        end
      end

      wpt.category = ((i = read_int16(io)) && i != 0)
      wpt.temperature = read_double(io) if read_boolean(io)

      if header.version <= 2
        if wptflag != 0
          read_meaningless_chars io, 1
        end
      end

      wpt.set_creation_time read_int(io) if read_boolean(io)

      wpt
    end

    def read_track(record)
      header = record.unpack('AZ*all')
      _, name, _, color, npoints = *header
      contents = record.sub(/^#{Regexp.quote(header.pack('AZ*all'))}/, '')

      track = Track.new(name, Color::from_index(color))
      io = StringIO.new(contents)

      0.upto(npoints - 1) do
        lat = semicircle_to_degrees(read_int(io))
        lon = semicircle_to_degrees(read_int(io))

        wpt = Waypoint.new(lat, lon)

        if read_boolean(io)
          alt = read_double(io)
          wpt.altitude = alt if alt < 1.0e24
        end

        wpt.creation_time = read_int(io) if read_boolean(io)
        wpt.depth = read_double(io) if read_boolean(io)
        wpt.temperature = read_double(io) if read_boolean(io)

        track.add_waypoint wpt
      end

      track
    end

    # Reads a string from an IO object.
    #
    # io - an IO object
    # chars - number of chars to read. If not specified, read_string stops at
    #   the null string terminator.
    #
    # Returns a string.
    def read_string(io, chars=nil)
      if chars
        io.read chars
      else
        str = ''
        while c = io.read(1)
          break if c == "\x00"
          str += c
        end

        str
      end
    end

    # Reads an Integer from an IO object, unpacking it appropriately.
    #
    # io - an IO object.
    #
    # Returns an Integer.
    def read_int(io)
      io.read(4).unpack('l').shift
    end

    def read_int16(io)
      io.read(2).unpack('s').shift
    end

    def read_meaningless_chars(io, number_of_chars)
      io.read number_of_chars
    end

    # Reads a Double from an IO object, unpacking it appropriately.
    #
    # io - an IO object.
    #
    # Returns an Double.
    def read_double(io)
      io.read(8).unpack('E').shift
    end

    # Reads a single character from an IO object, unpacking it
    #   appropriately.
    #
    # io - an IO object.
    #
    # Returns a single character.
    def read_char(io)
      io.read(1).unpack('c').shift
    end

    # Reads a boolean from an IO object.
    #
    # io - an IO object.
    #
    # Returns a single character.
    def read_boolean(io)
      read_char(io) == 1
    end

    # Reads a GDB's header to determine the version being parsed, its creator
    #   and signer.
    #
    # Returns a properly filled header.
    # Raises MapSource::InvalidFormatError if it's not a GDB file.
    # Raises MapSource::InvalidFormatError if GDB is malformed.
    # Raises MapSource::UnsupportedVersionError if file format version is not supported.
    def read_header
      header = Header.new

      mscrf = @gdb.read(6).unpack('A*').shift

      raise InvalidFormatError, "Invalid gdb file" if mscrf != 'MsRcf'

      record_length = @gdb.read(4).unpack('l').shift
      buffer = @gdb.read(record_length + 1)

      raise InvalidFormatError, "Invalid gdb file" if buffer[0] != ?D
      gdb_version = buffer[1].getbyte(0) - ?k.getbyte(0) + 1

      raise UnsupportedVersionError, "Unsupported version: #{gdb_version}. Supported versions are #{SUPPORTED_VERSIONS.to_a.join(', ')}" if !SUPPORTED_VERSIONS.member?(gdb_version)

      header.version = gdb_version

      record_length = @gdb.read(4).unpack('l').shift
      buffer = @gdb.read(record_length + 1)
      creator = buffer.unpack('Z*').shift

      header.created_by = if creator =~ /SQA$/
                            'MapSource'
                          elsif creator =~ /neaderhi$/
                            'MapSource BETA'
                          end

      signer = @gdb.read(10)
      signer += @gdb.read(1) until signer =~ /\x00$/

      signer = signer.unpack('Z*').shift

      if signer !~ /MapSource|BaseCamp/
        raise InvalidFormatError, "Unknown file signature: #{signer}"
      end

      header.signed_by = signer

      header
    end
  end
end
