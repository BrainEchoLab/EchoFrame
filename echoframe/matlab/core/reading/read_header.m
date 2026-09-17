function HeaderSpec = read_header(fileID)
% readHeader reads header information from a binary file.
% It supports version 0 (5 fields) and version 1 (6 fields) headers.
%
% HeaderSpec contains the following fields:
%   version           - header version (0 or 1)
%   headerSize        - total size of the header in bytes
%   buffersStored     - number of buffers stored
%   effectiveBufferSize  - effective buffer size (without padding)
%   paddingBytes      - padding bytes added to each buffer
%   dataType          - numeric data type code (only for version 1; NaN for version 0)

% Read the first 64-bit value to determine the header version.
version = fread(fileID, 1, '*uint64');
if isempty(version)
    error('Failed to read header version.');
end

if version == 0
    % Version 0 header has a total of 5 uint64 fields.
    extra = fread(fileID, 4, '*uint64');
    if numel(extra) < 4
        error('Incomplete version 0 header.');
    end
    HeaderSpec.version              = version;
    HeaderSpec.headerSize           = extra(1);
    HeaderSpec.buffersStored        = extra(2);
    HeaderSpec.effectiveBufferSize  = extra(3);
    HeaderSpec.paddingBytes         = extra(4);
    HeaderSpec.dataType             = NaN;
elseif version == 1
    % Version 1 header has 6 uint64 fields.
    extra = fread(fileID, 5, '*uint64');
    if numel(extra) < 5
        error('Incomplete version 1 header.');
    end
    HeaderSpec.version              = version;
    HeaderSpec.headerSize           = extra(1);
    HeaderSpec.buffersStored        = extra(2);
    HeaderSpec.effectiveBufferSize  = extra(3);
    HeaderSpec.paddingBytes         = extra(4);
    HeaderSpec.dataType             = extra(5);
else
    error('Unknown header version: %d', version);
end

% Move the file pointer to the end of the header
status = fseek(fileID, HeaderSpec.headerSize, 'bof');
if status ~= 0
    error('Failed to seek to the end of the header.');
end
end
