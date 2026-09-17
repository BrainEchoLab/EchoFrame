function [RF, HeaderSpec] = read_stored_RF(RFPath, ReceiveSpec, bufID)
%READ_STORED_RF  Read one RF buffer out of a stored rf_acq.dat.
%
%  [RF, HeaderSpec] = READ_STORED_RF(RFPATH, ReceiveSpec, BUFID) returns buffer
%  BUFID (0-based) as int16, shaped
%  [nSamples * nTransmissions * nRepeats, nChannels], along with the parsed
%  HeaderSpec. To stream a whole recording rather than pick single buffers, use
%  batch_loading instead.
%
%  See also read_header, batch_loading.

fileID = fopen(RFPath);

%% Get information about storage file from header
HeaderSpec = read_header(fileID);

%% Move after the header to first data buffer
status = fseek(fileID, HeaderSpec.headerSize, 'bof');
if status ~= 0
    fclose(fileID);
    error('read_stored_RF:seekFailed', 'fseek to the first data buffer failed.');
end

%% Get first RF frame
fseek(fileID, HeaderSpec.headerSize+ bufID*(HeaderSpec.effectiveBufferSize*2 + HeaderSpec.paddingBytes), 'bof');
RF = fread(fileID, [ReceiveSpec.nSamples * ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats, ReceiveSpec.nChannels], '*int16');

%% Close file
fclose(fileID);

end