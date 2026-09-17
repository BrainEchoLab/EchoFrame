function [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = init_storage(command, StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec)
%INIT_STORAGE  Build the per-stream storage specs and open the recording.
% Called by the acquisition/processing scripts (e.g. echoframe_acquisition_start.m,
% generate_echoframe_demo_data.m); COMMAND is 'init' or 're-init'.
%
%  [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec] = INIT_STORAGE(COMMAND, StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, TransmitSpec, ProbeSpec)
%  derives the beamformed, Power Doppler and RF-time-tag storage specs -- buffer
%  sizes, data types, file paths -- from the acquisition specs.
%
%  COMMAND is 'init' for a new recording or 're-init' to start another one with
%  the same acquisition.
%
%  StorageSpec must carry::
%
%    folderStoragePath   parent folder for the recording
%    saveBF, savePDI, saveRFTimeTag, saveRF
%                        which streams to write
%    preallocateFullFile whether to size files up front
%
%  Optional bfFilename / pdiFilename / rfTimeTagFilename / rfFilename override
%  the defaults (bf_acq, pdi_acq, rfTimeTag_acq, rf_acq).
%
%  Beyond returning the specs it also::
%
%    - creates a timestamped recording_<date> folder under folderStoragePath
%    - writes ScanParameters.mat there with all six spec structs
%    - builds RFStorageSpec, when StorageSpec.saveRF is set
%    - assigns StorageSpec into the base workspace
%
%  With preallocateFullFile true, each file is sized for
%  ExperimentSpec.numberOfPDIsExperiment buffers. With it false, for as many
%  buffers as fit under a 200 GB cap.
%
%  RFStorageSpec is passed to echoframe_mex('init') as its 8th argument; the
%  core opens the RF file from it.

%% General Max Size Calculations
maxSizeWriteGB     = 200; % max size to write in GB
maxCapacityGB      = 3000; % max capacity of the disk (currently set at 3 TB)
if (maxSizeWriteGB > maxCapacityGB)
    maxSizeWriteGB = maxCapacityGB;
end
maxSizeWriteBytes  = maxSizeWriteGB * 1024 * 1024 * 1024;

%% Create Folder for each experiment
recordingCreatedTime                    = now; %#ok<TNOW1> serial datenum of folder creation
StorageSpec.filenameDate                = datestr(recordingCreatedTime, 'YYYY-mm-DD_HHMMSS');
% No trailing separator: a literal '\' is part of the folder NAME on Linux
% (fullfile does not normalise it), which produced directories called
% "recording_2026-08-31_124613\". Callers that need a trailing separator should
% use fullfile themselves.
StorageSpec.experimentStoragePath       = fullfile(StorageSpec.folderStoragePath, sprintf('%s_%s', 'recording', StorageSpec.filenameDate));
if ~isfolder(StorageSpec.experimentStoragePath)
    mkdir(StorageSpec.experimentStoragePath);
end
StorageSpec.recordingCreatedTime        = recordingCreatedTime;   % kept for finalize_recording_info

%% BF Definition
BFStorageSpec.crop                          = ReconSpec.cropBF;
if BFStorageSpec.crop
    bfDataSize                              = uint64((ReconSpec.croppingROI(2) - ReconSpec.croppingROI(1) + 1)*...
        (ReconSpec.croppingROI(4) - ReconSpec.croppingROI(3) + 1)*...
        ReceiveSpec.nRepeats);
else
    bfDataSize                              = uint64(ReconSpec.nz * ReconSpec.nx * ReceiveSpec.nRepeats);
end
bfDataSizeBytes                             = bfDataSize * 8; % complex single = 8 B/element (2 floats); only caps maxNumberBuffers when not preallocating
BFStorageSpec.save                          = StorageSpec.saveBF;
if StorageSpec.preallocateFullFile
    BFStorageSpec.maxNumberBuffers          = int32(ExperimentSpec.numberOfPDIsExperiment);
else
    BFStorageSpec.maxNumberBuffers          = int32(maxSizeWriteBytes / bfDataSizeBytes);
end
BFStorageSpec.numberOfBuffers               = int32(4);
BFStorageSpec.dataType                      = ReconSpec.bfDataType;
if isfield(StorageSpec, 'bfFilename') && ~isempty(StorageSpec.bfFilename)
    bfFilename                              = StorageSpec.bfFilename;
else
    bfFilename                              = 'bf_acq';
end
BFStorageSpec.filepath                      = fullfile(StorageSpec.experimentStoragePath, bfFilename);
BFStorageSpec.bufferSize                    = uint64(bfDataSize);
BFStorageSpec.preallocateFullFile           = StorageSpec.preallocateFullFile;

%% PDI Definition
PDIStorageSpec.crop                         = PDISpec.cropPDI;
if PDIStorageSpec.crop
    pdiDataSize                             = uint64((ReconSpec.croppingROI(2) - ReconSpec.croppingROI(1) + 1) *...
        (ReconSpec.croppingROI(4) - ReconSpec.croppingROI(3) + 1) *...
        max(0, floor((double(ReceiveSpec.nRepeats) - double(PDISpec.ensembleSize)) / double(PDISpec.shiftSize)) + 1));
else
    pdiDataSize                             = uint64((ReconSpec.nz * ReconSpec.nx)*max(0,floor((ReceiveSpec.nRepeats - PDISpec.ensembleSize) / PDISpec.shiftSize) + 1));
end
pdiDataSizeBytes                            = pdiDataSize * 4;
PDIStorageSpec.save                         = StorageSpec.savePDI;
if StorageSpec.preallocateFullFile
    PDIStorageSpec.maxNumberBuffers         = int32(ExperimentSpec.numberOfPDIsExperiment);
else
    PDIStorageSpec.maxNumberBuffers         = int32(maxSizeWriteBytes / pdiDataSizeBytes);
end
PDIStorageSpec.numberOfBuffers              = int32(4);
PDIStorageSpec.dataType                     = 'single';
if isfield(StorageSpec, 'pdiFilename') && ~isempty(StorageSpec.pdiFilename)
    pdiFilename                             = StorageSpec.pdiFilename;
else
    pdiFilename                             = 'pdi_acq';
end
PDIStorageSpec.filepath                     = fullfile(StorageSpec.experimentStoragePath, pdiFilename);
PDIStorageSpec.bufferSize                   = uint64(pdiDataSize);
PDIStorageSpec.preallocateFullFile          = StorageSpec.preallocateFullFile;

%% RF Time Tag Definition
RFTimeTagStorageSpec.crop                   = logical(false);
rfTimeTagDataSize                           = uint64(ReceiveSpec.nRepeats * ReceiveSpec.nTransmissions);
rfTimeTagDataSizeBytes                      = rfTimeTagDataSize * 4;
RFTimeTagStorageSpec.save                   = StorageSpec.saveRFTimeTag;
if StorageSpec.preallocateFullFile
    RFTimeTagStorageSpec.maxNumberBuffers   = int32(ExperimentSpec.numberOfPDIsExperiment);
else
    RFTimeTagStorageSpec.maxNumberBuffers   = int32(maxSizeWriteBytes / rfTimeTagDataSizeBytes);
end
RFTimeTagStorageSpec.numberOfBuffers        = int32(4);
RFTimeTagStorageSpec.dataType               = 'double';
if isfield(StorageSpec, 'rfTimeTagFilename') && ~isempty(StorageSpec.rfTimeTagFilename)
    rfTimeTagFilename                       = StorageSpec.rfTimeTagFilename;
else
    rfTimeTagFilename                       = 'rfTimeTag_acq';
end
RFTimeTagStorageSpec.filepath               = fullfile(StorageSpec.experimentStoragePath, rfTimeTagFilename);
RFTimeTagStorageSpec.bufferSize             = uint64(rfTimeTagDataSize);
RFTimeTagStorageSpec.preallocateFullFile    = StorageSpec.preallocateFullFile;

% % RF storage Definition
% numberOfBuffers is the RF write queue depth: numberOfBuffers-1 writes may be
% in flight. Depth hides write latency, so too small a value makes storeBuffer
% block, but depth beyond the acquisition ring is unsafe: RF aliases that ring,
% and the hardware may overwrite a frame once nBuffers frames have passed.
% Matching the two makes the queue block one frame before the ring wraps.
% EF_RF_STORAGE_BUFFERS overrides it at runtime; raise it only together with
% ReceiveSpec.nBuffers, and only if check_storage_headroom says to.
rfDataSize = [ReceiveSpec.nSamples, ReceiveSpec.nTransmissions, ReceiveSpec.nRepeats, ReceiveSpec.nChannels];
rfDataSize = uint64(prod(rfDataSize));
rfDataSizeBytes = rfDataSize * 2;
if StorageSpec.preallocateFullFile 
    rfMaxNumberBuffers = int32(ExperimentSpec.numberOfPDIsExperiment);
else
    rfMaxNumberBuffers = int32(maxSizeWriteBytes / rfDataSizeBytes);
end 
if isfield (StorageSpec, 'rfFilename') && ~isempty(StorageSpec.rfFilename)
    rfFilename = StorageSpec.rfFilename;
else
    rfFilename = 'rf_acq';
end
% Queue depth follows the acquisition ring; 4 matches the shipped setup scripts.
if isfield(ReceiveSpec, 'nBuffers') && ~isempty(ReceiveSpec.nBuffers)
    rfNumberOfBuffers = int32(max(2, double(ReceiveSpec.nBuffers)));
else
    rfNumberOfBuffers = int32(4);
end
RFStorageSpec = struct(... 
    'save', logical(StorageSpec.saveRF), ... 
    'crop', logical(false),... 
    'preallocateFullFile', logical(StorageSpec.preallocateFullFile), ... 
    'maxNumberBuffers', rfMaxNumberBuffers, ... 
    'numberOfBuffers', rfNumberOfBuffers, ... % see note above
    'dataType', 'int16', ... 
    'filepath', fullfile(StorageSpec.experimentStoragePath, rfFilename), ... 
    'bufferSize', uint64(rfDataSize)...
    );

% The acquisition ring must outlast the write queue: a frame handed to
% storeBuffer is still being written for up to numberOfBuffers-1 frames, and the
% hardware is free to overwrite it after nBuffers frames. Without this the
% stored RF is silently corrupted rather than failing loudly.
% EF_RF_STORAGE_BUFFERS overrides the depth inside the MEX, so report against
% the value that will actually be used.
if StorageSpec.saveRF
    rfDepthEnv = getenv('EF_RF_STORAGE_BUFFERS');
    rfDepth    = double(RFStorageSpec.numberOfBuffers);
    if ~isempty(rfDepthEnv)
        overridden = str2double(rfDepthEnv);
        if ~isnan(overridden) && overridden > 0
            fprintf(['RF storage depth overridden by EF_RF_STORAGE_BUFFERS: ' ...
                     '%d -> %d.\n'], rfDepth, overridden);
            rfDepth = overridden;
        end
    end
    rfInFlight = rfDepth - 1;

    if ~isfield(ReceiveSpec, 'nBuffers') || isempty(ReceiveSpec.nBuffers)
        warning('init_storage:rfRingUnknown', ...
                ['ReceiveSpec.nBuffers is not set, so the acquisition ring ' ...
                 'depth is whatever Vantage defaults to and the RF write ' ...
                 'queue cannot be checked against it. Set ' ...
                 'Resource.RcvBuffer(1).numFrames = ReceiveSpec.nBuffers in ' ...
                 'the setup script.']);
    elseif rfInFlight >= double(ReceiveSpec.nBuffers)
        warning('init_storage:rfRingTooShallow', ...
                ['RF writes in flight (%d) exceed the acquisition ring depth ' ...
                 '(ReceiveSpec.nBuffers = %d), so stored RF can be overwritten ' ...
                 'while it is still being written. Raise nBuffers, or lower ' ...
                 'RFStorageSpec.numberOfBuffers.'], ...
                rfInFlight, double(ReceiveSpec.nBuffers));
    else
        fprintf(['RF storage: %d buffers (%d write(s) in flight) against an ' ...
                 'acquisition ring of %d frames -- a buffer cannot be reused ' ...
                 'while its write is running.\n'], ...
                rfDepth, rfInFlight, ReceiveSpec.nBuffers);
        fprintf('  Run check_storage_headroom afterwards to check the depth.\n');
        % One write in flight means storeBuffer waits for each RF write to
        % finish before returning, which adds the full write time to every
        % frame. Overlap needs a deeper acquisition ring, since the queue
        % cannot exceed it.
        if rfInFlight < 2
            warning('init_storage:rfNoWriteOverlap', ...
                    ['RF writes cannot overlap at ReceiveSpec.nBuffers = %d, ' ...
                     'so each frame waits for its own write. Raise nBuffers ' ...
                     '(4 gives 3 writes in flight) at the cost of one RF ' ...
                     'frame of RcvBuffer memory per slot.'], ...
                    double(ReceiveSpec.nBuffers));
        end
    end
end

%% Store ScanParameters(ReceiveSpec, ReconSpec, PDISpec, ExperimentSpec, ExperimentSpec,ProbeSpec) 
if BFStorageSpec.save || PDIStorageSpec.save || RFTimeTagStorageSpec.save || RFStorageSpec.save
    parameter_filename = fullfile(StorageSpec.experimentStoragePath,'ScanParameters.mat');
    save(parameter_filename, 'ReceiveSpec', 'ReconSpec', 'PDISpec', 'ExperimentSpec', 'TransmitSpec','ProbeSpec', '-v7.3');

% Stamp the folder-creation time now; finalize_recording_info appends the 
% recording-end time once acquisition stops (see that function).
    write_recording_info_start(StorageSpec.experimentStoragePath, recordingCreatedTime);
end

%% Assignin base for future usage
assignin('base','StorageSpec', StorageSpec);

end
