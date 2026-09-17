classdef batch_demo_data
% batch_demo_data - Shared dataset generation for the verify_batch_* GPU tests.
%
% Shared setup for the verify_batch_* GPU tests: the acquisition specs and the
% "simulate one logo buffer, add per-buffer noise, write N buffers through the
% storage path" generation, in one place. TEST-ONLY support -- pulls in
% simulate_logo_rf, init_storage and echoframe_mex; the production batch_loading
% class depends only on read_header.
%
% Typical use:
%   prep          = batch_demo_data.prepare();                       % specs + one base RF buffer + geometry
%   recording_dir = batch_demo_data.writeBuffers(prep, out_dir, N, noiseStd, saveBF, saveRF);
%   S = load(fullfile(recording_dir, 'ScanParameters.mat'));         % reload the specs, then read the .dat
%
% prepare() returns the per-buffer geometry (incl. prep.bytesPerBuffer); a caller
% can read it and choose N_BUFFERS before writeBuffers() writes anything.

    methods (Static)
        function [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = specs()
            % The acquisition specs shared by every batch verification harness.
            ProbeSpec.pitch = 300e-6; ProbeSpec.Fc = 5e6; ProbeSpec.nElements = 128;
            TransmitSpec.c0 = 1540; TransmitSpec.type = 'planewave';
            TransmitSpec.steer = [-10 0 10];
            TransmitSpec.apodization = ones(ProbeSpec.nElements, 1);
            ReceiveSpec.nRepeats = 40; ReceiveSpec.Fs = 20e6;
            ReceiveSpec.nTransmissions = numel(TransmitSpec.steer);
            ReceiveSpec.samplingMode = 'BS100BW'; ReceiveSpec.nBuffers = 1;
            ReconSpec.bfDataType = 'complex single'; ReconSpec.filterFrequencies = false;
            ReconSpec.getBF = true; ReconSpec.getPDI = false;
            ReconSpec.extraVoxelsZ = 0; ReconSpec.extraVoxelsX = 128;
            ReconSpec.c0 = TransmitSpec.c0; ReconSpec.cropBF = false;
            ReconSpec.croppingROI = [0; 128; 0; 128];
            PDISpec.ensembleSize = ReceiveSpec.nRepeats; PDISpec.threshold = single(0.4);
            PDISpec.shiftSize = ReceiveSpec.nRepeats; PDISpec.cropPDI = false;
            PDISpec.svdMethod = 'Covariance';
        end

        function prep = prepare()
            % Simulate one base RF buffer and initialise reconstruction, so the
            % caller knows the per-buffer geometry before choosing how many buffers
            % to write. Returns everything writeBuffers needs plus the geometry.
            [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = batch_demo_data.specs();
            [RF_base, ProbeSpec, TransmitSpec, ReceiveSpec] = ...
                simulate_logo_rf(ProbeSpec, TransmitSpec, ReceiveSpec);
            ReceiveSpec.nSamplesIQ = ReceiveSpec.nSamples / 2;
            [ProbeSpec, ReceiveSpec, ReconSpec] = ...
                initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);
            prep.ProbeSpec   = ProbeSpec;   prep.TransmitSpec = TransmitSpec;
            prep.ReceiveSpec = ReceiveSpec; prep.ReconSpec    = ReconSpec;
            prep.PDISpec     = PDISpec;     prep.RF_base      = RF_base;
            prep.nz       = double(ReconSpec.nz);
            prep.nx       = double(ReconSpec.nx);
            prep.nRepeats = double(ReceiveSpec.nRepeats);
            prep.bytesPerBuffer = prep.nz * prep.nx * prep.nRepeats * 8;   % complex-single BF buffer
        end

        function [recording_dir, StorageSpec] = writeBuffers(prep, output_dir, N_BUFFERS, noiseStd, saveBF, saveRF)
            % Write N_BUFFERS noisy variants of prep.RF_base through the storage
            % path and return the timestamped recording folder (and the StorageSpec
            % init_storage produced, so a caller can reuse it for a processing-phase
            % init). Mirrors generate_echoframe_demo_data: saveBF -> bf_acq.dat
            % and saveRF -> rf_acq.dat, both written inside echoframe_mex (RF via
            % the RFStorageSpec passed to 'init').
            % ScanParameters.mat is written by init_storage whenever a stream saves.
            if exist(output_dir, 'dir'), rmdir(output_dir, 's'); end
            mkdir(output_dir);

            StorageSpec.folderStoragePath   = output_dir;
            StorageSpec.saveRF              = saveRF;
            StorageSpec.saveBF              = saveBF;
            StorageSpec.savePDI            = false;
            StorageSpec.saveRFTimeTag       = false;
            StorageSpec.preallocateFullFile = true;
            ExperimentSpec.numberOfPDIsExperiment = N_BUFFERS;

            ProbeSpec = prep.ProbeSpec; TransmitSpec = prep.TransmitSpec;
            ReceiveSpec = prep.ReceiveSpec; ReconSpec = prep.ReconSpec; PDISpec = prep.PDISpec;

            % init_storage first (uses the un-validated specs), then validate, then
            % the MEX -- the same order every harness used before extraction.
            [BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec] = ...
                init_storage('init', StorageSpec, ReceiveSpec, ReconSpec, PDISpec, ...
                             ExperimentSpec, TransmitSpec, ProbeSpec);
            [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ...
                echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec); %#ok<ASGLU>
            echoframe_mex('init', ReceiveSpec, ReconSpec, PDISpec, ...
                          BFStorageSpec, PDIStorageSpec, RFTimeTagStorageSpec, RFStorageSpec);
            StorageSpec   = evalin('base', 'StorageSpec');   % init_storage stamps experimentStoragePath here
            recording_dir = StorageSpec.experimentStoragePath;

            rng(1);   % deterministic per-buffer noise
            for k = 1:N_BUFFERS
                RF = prep.RF_base + int16(round(noiseStd * randn(size(prep.RF_base))));
                echoframe_mex('process', RF, true);   % beamform + write rf_acq.dat/bf_acq.dat per storage specs
                if saveRF, mark_first_write(recording_dir); end
            end
            echoframe_mex('destroy');                           % release BF/RF file handles before clear mex
            clear mex;                                          % flushes bf_acq.dat / rf_acq.dat headers
            if saveRF, finalize_recording_info(recording_dir); end
        end
    end
end
