% read_stored_BF - Inspect a stored beamformed recording (bf_acq.dat) by hand.
%
% Reads every buffer, rebuilds the complex frames from the interleaved I/Q
% singles, and shows B-mode next to an SVD-filtered frame. Point load_path at a
% recording folder and run.
%
% Prereq: ECHOFRAME_PATH env var; a recording folder holding bf_acq.dat and
%         ScanParameters.mat.

clear;
close all;

%% EchoFrame paths
ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
addpath(genpath(fullfile(ECHOFRAME_PATH)));
check_echoframe_path(ECHOFRAME_PATH);

%% Adjust load_path and filename to your specific experiment.
load_path = '';
filename = 'bf_acq';

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
dataComplex = [];

%% Read data for each buffer
figure;
for i = 1:HeaderSpec.buffersStored
    % Read a buffer of 'single' data
    dataChunkRaw = fread(fileID, 2 * HeaderSpec.effectiveBufferSize, '*single');
    
    % Convert the raw data to complex numbers
    dataChunkComplex = dataChunkRaw(1:2:end) + 1i * dataChunkRaw(2:2:end);
    
    % Append this buffer's data to the full data array
    dataComplex = [dataComplex; dataChunkComplex];
    
    %% Example Code what to Do with each BF buffer
    % A recording made with cropBF stored only the ROI, so the frame on disk is
    % smaller than the full grid. stored_frame_size knows which is which.
    [nz, nx] = stored_frame_size(ReconSpec, ReconSpec.cropBF);
    BF = reshape(dataChunkComplex, nz, nx, double(ReceiveSpec.nRepeats));
    
    Bmode = abs(BF(:,:,1));
    Bmode = Bmode./max(Bmode(:));
    Bmode = 20*log10(Bmode+1e-12);
    
    %     figure;
    subplot(1,2,1)
    imshow(Bmode, [])
    colormap(gray);
    clim([-40 0])
    colorbar;
    shading interp, axis equal ij tight
    %     close
    
    [U,S,V] = svd(reshape(BF,[size(BF,1)*size(BF,2), size(BF,3)]),'econ');
    S0 = S;
    S0(1:20,1:20) = 0;
    BF2 = U*S0*V';
    BF2 = reshape(BF2,size(BF));
    
    subplot(1,2,2)
    imagesc(20*log10(mean(abs(BF2(:,:,end)),3)));
    
    sgtitle(num2str(i));
    drawnow
    
    status = fseek(fileID, HeaderSpec.paddingBytes, 'cof');
    if status ~= 0
        fclose(fileID);
        error('read_stored_BF:seekFailed', ...
              'fseek past the padding of buffer %d failed.', i);
    end
end

fclose(fileID);