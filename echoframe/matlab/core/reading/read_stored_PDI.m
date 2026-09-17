% read_stored_PDI - Inspect a stored Power Doppler recording (pdi_acq.dat) by hand.
%
% Reads every buffer, reshapes it into the PDI frames the acquisition produced,
% and shows each one in dB. Point load_path at a recording folder and run.
%
% Prereq: ECHOFRAME_PATH env var; a recording folder holding pdi_acq.dat and
%         ScanParameters.mat.

clear;
close all;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

%% Adjust load_path and filename to your specific experiment.
load_path = '';
filename = 'pdi_acq';

filepath = fullfile(load_path, filename);
filepath = strcat(filepath,'.dat');
fileID = fopen(filepath);

reconPath = fullfile(load_path, 'ScanParameters.mat');
load(reconPath);

%% Get information about storage file from header
HeaderSpec = read_header(fileID);

% Move the file read position to the end of the header
fseek(fileID, HeaderSpec.headerSize, 'bof');

%% Initialize an array to hold all the data
dataSingle = [];

%% Read data for each buffer
for i = 1:HeaderSpec.buffersStored
    % Read a buffer of 'single' data
    dataChunkSingle = fread(fileID, HeaderSpec.effectiveBufferSize, '*single');
    
    % Append this buffer's data to the full data array
    dataSingle = [dataSingle; dataChunkSingle];
    
    %% Example Code what to Do with each PDI buffer
    % Frames per buffer. Cast to double first: the specs load from
    % ScanParameters.mat as int32, and int32 division in MATLAB rounds instead
    % of truncating, which would give the wrong ensemble count.
    nEnsembles = max(0, floor((double(ReceiveSpec.nRepeats) - double(PDISpec.ensembleSize)) ...
                              / double(PDISpec.shiftSize)) + 1);
    % cropPDI stored only the ROI; stored_frame_size returns whichever applies.
    [nz, nx] = stored_frame_size(ReconSpec, PDISpec.cropPDI);
    PDI = reshape(dataChunkSingle, nz, nx, nEnsembles);
    for idx = 1:size(PDI, 3)
        PDI_frame = PDI(:,:,idx);
        PDI_norm_db  = 10*log10(PDI_frame ./ max(PDI_frame(:)));
        figure();
        imagesc(PDI_norm_db);
        colormap hot;
        colorbar;
        title(['PDI Frame ' num2str(idx)]);
        pause(0.1);
    end
    
    status = fseek(fileID, HeaderSpec.paddingBytes, 'cof');
    if status ~= 0
        fclose(fileID);
        error('read_stored_PDI:seekFailed', ...
              'fseek past the padding of buffer %d failed.', i);
    end
end

fclose(fileID);