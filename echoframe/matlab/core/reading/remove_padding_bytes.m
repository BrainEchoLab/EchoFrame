% remove_padding_bytes - Rewrite a stored .dat without its per-buffer padding.
%
% EchoFrame's storage layer pads every buffer out to a whole number of physical
% sectors so writes stay aligned. This copies a recording into a new file with
% that padding stripped and the header's padding field zeroed, giving a dense
% stream a reader can walk without skipping between buffers.
%
% The element type comes from the header. Version 1 headers carry a dataType
% code, so RF (int16), PDI (single), BF (complex single) and time-tag (double)
% recordings are all handled. Version 0 headers predate that field and are
% assumed to be complex single -- the beamformed case, which is what this script
% assumed unconditionally before.
%
% Prereq: ECHOFRAME_PATH env var; a recording folder holding the .dat to clean.
% Usage:  fill in the file paths below; run.

clear;
close all;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

%% File paths -- filenames are given without the .dat extension.
load_path        = '';
originalFilename = '';
cleanFilename    = '';

VERBOSE = false;   % true prints per-buffer file positions

originalFilepath = fullfile(load_path, originalFilename);
originalFilepath = strcat(originalFilepath, '.dat');
cleanFilepath = fullfile(load_path, cleanFilename);
cleanFilepath = strcat(cleanFilepath, '.dat');

% Open the original file for reading and the new file for writing
fileID_original = fopen(originalFilepath, 'r', 'ieee-le'); % Adjust endianness if needed
fileID_clean = fopen(cleanFilepath, 'w', 'ieee-le'); % Adjust endianness if needed

%% Get information about storage file from header
HeaderSpec = read_header(fileID_original);

% How to read one buffer, from the header's dataType code.
[precision, elementsPerValue, bytesPerElement] = decode_data_type(HeaderSpec.dataType);
elementsPerBuffer = double(HeaderSpec.effectiveBufferSize) * elementsPerValue;

%% Copy the header verbatim, using the header size parsed from the file
% read_header left the file at the end of the header; rewind and read exactly
% HeaderSpec.headerSize bytes (always a whole number of uint64).
fseek(fileID_original, 0, 'bof');
numHeaderElements = HeaderSpec.headerSize / 8;
header = fread(fileID_original, numHeaderElements, '*uint64');

% Zero the padding field (field[4], 1-indexed 5) since the cleaned file has none.
% That index holds paddingBytes in both the version 0 and version 1 layouts.
header_new = header;
header_new(5) = uint64(0);
fwrite(fileID_clean, header_new, 'uint64');

% Position both files at the end of the header before copying data.
fseek(fileID_original, HeaderSpec.headerSize, 'bof');
fseek(fileID_clean, HeaderSpec.headerSize, 'bof');

%% Debugging Information
fprintf('Header version %d, data type %s (%d element(s) per value)\n', ...
    HeaderSpec.version, precision, elementsPerValue);
fprintf('Expected HeaderSpec.effectiveBufferSize: %d\n', HeaderSpec.effectiveBufferSize);
fprintf('Expected total file size after removing padding: %d bytes\n', ...
    double(HeaderSpec.headerSize) + ...
    double(HeaderSpec.buffersStored) * elementsPerBuffer * bytesPerElement);

%% Copy the data, dropping the padding after each buffer
for bufferIdx = 1:HeaderSpec.buffersStored
    if VERBOSE
        fprintf('Buffer %d - Original file position before reading data: %d\n', bufferIdx, ftell(fileID_original));
        fprintf('Buffer %d - Cleaned file position before writing data: %d\n', bufferIdx, ftell(fileID_clean));
    end

    % Read the actual data from the buffer
    data_chunk_raw = fread(fileID_original, elementsPerBuffer, ['*' precision]);

    % Check if fread returned less than expected (EOF check)
    data_chunk_size = length(data_chunk_raw);
    if data_chunk_size < elementsPerBuffer
        fprintf('Warning: Incomplete data in buffer %d. Read %d elements instead of %d.\n', ...
                bufferIdx, data_chunk_size, elementsPerBuffer);
        if data_chunk_size == 0
            break;  % Exit if no data was read
        end
    end

    % Write only the data that was read to the new file
    fwrite(fileID_clean, data_chunk_raw, precision);

    if VERBOSE
        fprintf('Buffer %d - Original file position after reading data: %d\n', bufferIdx, ftell(fileID_original));
        fprintf('Buffer %d - Cleaned file position after writing data: %d\n', bufferIdx, ftell(fileID_clean));
    end

    status = fseek(fileID_original, HeaderSpec.paddingBytes, 'cof');
    if status ~= 0
        fclose(fileID_original);
        fclose(fileID_clean);
        error('remove_padding_bytes:seekFailed', ...
              'fseek past the padding of buffer %d failed.', bufferIdx);
    end
end

%% Close both files
fclose(fileID_original);
fclose(fileID_clean);

%% Check final cleaned file size
fileInfo = dir(cleanFilepath);
fprintf('Final cleaned file size: %d bytes\n', fileInfo.bytes);
fprintf('File copied without padding bytes to %s\n', cleanFilepath);


function [precision, elementsPerValue, bytesPerElement] = decode_data_type(dataType)
%DECODE_DATA_TYPE  Map a stored header dataType code onto how to read it.
%  Codes match DataTypeCode in echoframe/cpp/libs/Storage/src/storage/Handler.h.
%  elementsPerValue is 2 for the complex types, whose I/Q components are stored
%  interleaved, so effectiveBufferSize counts complex values rather than reals.

if isnan(dataType)
    % Version 0 header: no dataType field. Assume the beamformed case, which is
    % what this script assumed for every file before the field existed.
    warning('remove_padding_bytes:noDataType', ...
            ['Version 0 header carries no dataType; assuming complex single. ', ...
             'If this is an RF (int16), PDI (single) or time-tag (double) ', ...
             'recording, set precision by hand.']);
    precision = 'single'; elementsPerValue = 2; bytesPerElement = 4;
    return
end

switch dataType
    case 1   % DT_INT16
        precision = 'int16';  elementsPerValue = 1; bytesPerElement = 2;
    case 2   % DT_SINGLE
        precision = 'single'; elementsPerValue = 1; bytesPerElement = 4;
    case 3   % DT_COMPLEX_SINGLE
        precision = 'single'; elementsPerValue = 2; bytesPerElement = 4;
    case 4   % DT_DOUBLE
        precision = 'double'; elementsPerValue = 1; bytesPerElement = 8;
    case 5   % DT_COMPLEX_DOUBLE
        precision = 'double'; elementsPerValue = 2; bytesPerElement = 8;
    otherwise
        % DT_UNKNOWN (0) and the bfloat codes (6, 7), which MATLAB's fread
        % cannot express directly.
        error('remove_padding_bytes:unsupportedDataType', ...
              'Header dataType code %d is not supported by this script.', dataType);
end
end
