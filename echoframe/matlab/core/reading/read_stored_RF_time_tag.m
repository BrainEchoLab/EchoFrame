% read_stored_RF_time_tag - Inspect a stored RF time-tag recording by hand.
%
% Each buffer holds the acquisition time tags written alongside the RF, as
% doubles (see init_storage, RFTimeTagStorageSpec.dataType). This reads every
% buffer, concatenates them, and plots the result. Point load_path at a recording
% folder and run.
%
% Prereq: ECHOFRAME_PATH env var; a recording folder holding the time-tag .dat
%         and ScanParameters.mat.

clear;
close all;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

%% Adjust load_path and filename to your specific experiment.
load_path = '';
filename = 'rf_timetag';

filepath = fullfile(load_path, filename);
filepath = strcat(filepath,'.dat');
fileID = fopen(filepath);

reconPath = fullfile(load_path, 'ScanParameters.mat');
load(reconPath);

%% Get information about storage file from header
% read_header parses both the 5-field (version 0) and 6-field (version 1)
% headers and leaves the file positioned at the first data buffer.
HeaderSpec = read_header(fileID);

%% Initialize an array to hold all the data
data_double = [];

%% Read data for each buffer
for i = 1:HeaderSpec.buffersStored
    % Read a buffer of 'double' data
    data_chunk_double = fread(fileID, HeaderSpec.effectiveBufferSize, '*double');

    % Append this buffer's data to the full data array
    data_double = [data_double; data_chunk_double];

    %% Example Code what to Do with each buffer

    status = fseek(fileID, HeaderSpec.paddingBytes, 'cof');
    if status ~= 0
        fclose(fileID);
        error('read_stored_RF_time_tag:seekFailed', ...
              'fseek past the padding of buffer %d failed.', i);
    end
end

figure(3);
plot(data_double);
grid on;

fclose(fileID);
