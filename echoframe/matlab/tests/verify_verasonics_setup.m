% verify_verasonics_setup - Exercise the Verasonics probe-setup path without transmitting.
%
% Runs the setup half of echoframe_acquisition_start.m for every probe script,
% and stops right before VSX. That covers the four Verasonics files that finish
% on their own:
%
%   L74_demo.m / GE9LD_demo.m  - build Trans / TW / TX / Receive / TGC / Process /
%                                SeqControl / Event plus the EchoFrame specs
%   vsx_to_ef_structs.m        - Verasonics structures -> EchoFrame specs
%   setup_echoframe_figure.m   - the live B-mode + PDI figure
%
% echoframe_acquisition_start.m itself is NOT run: it ends in VSX, which blocks
% in the Verasonics GUI until an operator closes it, and it transmits for
% EXPERIMENT_TIME seconds and writes a recording. This harness stops before all
% of that. Resource.Parameters.simulateMode is 1, so nothing is transmitted.
%
% MUST RUN IN THE BASE WORKSPACE, like echoframe_acquisition_start.m does. The
% Verasonics helpers read their inputs with evalin('base', ...) - computeTXDelays
% fetches Trans that way - and the probe scripts publish to base by declaring
% globals, which only links base's variables when the script itself runs in base.
% Called from inside a function it fails with "Trans.type must be specified".
% run_all_matlab invokes it through evalin('base', ...) for this reason.
%
% Each probe is run independently and its failure recorded, so a probe whose
% connector is not present (GE9LD needs the GE connector) does not hide the
% result for the other one. The script errors at the end if any probe failed.
%
% Prereq: Verasonics Vantage installation, VERASONICS_VPF_ROOT env var,
%         ECHOFRAME_PATH env var. No hardware transmission, no storage, no MEX.
% Usage:  run it from the MATLAB prompt.
%
% See also echoframe_acquisition_start, vsx_to_ef_structs, get_system_parameters.

clear; close all; clear mex;

%% ------------------------------------------------------- activate Vantage
% activate clears the base workspace, so it runs before anything is defined and
% the return path is stashed in an environment variable - variables and globals
% do not survive it, env vars do.
if isempty(getenv('VERASONICS_VPF_ROOT')) || ~isfolder(getenv('VERASONICS_VPF_ROOT'))
    error('verify_verasonics_setup:noVantage', ...
          ['VERASONICS_VPF_ROOT is not set or does not point at a folder. ', ...
           'This harness needs a Vantage installation for computeTrans / ', ...
           'computeTXDelays.']);
end
setenv('EF_VERASONICS_STARTDIR', pwd);
fprintf('Activating Vantage at %s ...\n', getenv('VERASONICS_VPF_ROOT'));
cd(getenv('VERASONICS_VPF_ROOT'));
activate;                                     % <- wipes the base workspace
cd(getenv('EF_VERASONICS_STARTDIR'));
setenv('EF_VERASONICS_STARTDIR', '');

%% ------------------------------------------------------------ environment
ef_probes  = {'L74_demo', 'GE9LD_demo'};
ef_results = struct('probe', ef_probes, 'ok', false, 'msg', '');

ECHOFRAME_PATH = getenv('ECHOFRAME_PATH');
if isempty(ECHOFRAME_PATH)
    error('verify_verasonics_setup:noPath', 'ECHOFRAME_PATH is not set.');
end
addpath(genpath(ECHOFRAME_PATH));
check_echoframe_path(ECHOFRAME_PATH);

%% ------------------------------------------------------------------- run
for ef_p = 1:numel(ef_probes)
    fprintf('\n============ %s ============\n', ef_probes{ef_p});
    try
        % --- fresh Verasonics state for this probe
        clear global
        clear TX TW Trans Receive Resource absoluteTime
        clear ProbeSpec TransmitSpec ReceiveSpec ReconSpec PDISpec

        % Declared here, in base, exactly as echoframe_acquisition_start.m does.
        % This is what links base's variables to the globals the probe scripts
        % and the Verasonics helpers expect to find.
        global TX TW Trans Receive Resource absoluteTime %#ok<GVMIS,NUSED>
        global ProbeSpec TransmitSpec ReceiveSpec ReconSpec %#ok<GVMIS>

        % Time tagging talks to the hardware adapter. It is not needed to build
        % the structures, so a machine without the HAL still gets checked.
        try
            import com.verasonics.hal.hardware.*
            Hardware.enableAcquisitionTimeTagging(true);
            Hardware.setTimeTaggingAttributes(false, true);
        catch ef_halErr
            fprintf('  (skipping time tagging: %s)\n', ef_halErr.message);
        end

        Resource.Parameters.simulateMode      = 1;   % 1 = simulate; nothing is transmitted
        Resource.Parameters.waitForProcessing = 1;
        Resource.Parameters.numTransmit       = 256;
        Resource.Parameters.numRcvChannels    = 256;
        Resource.VDAS.dmaTimeout              = 120 * 1000;
        Resource.Parameters.GUI               = 'vsx_gui';

        % --- the probe setup script itself
        fprintf('  running %s ...\n', ef_probes{ef_p});
        eval(ef_probes{ef_p});

        assert(~isempty(Trans) && isfield(Trans, 'frequency'), 'Trans was not built');
        assert(~isempty(TX),      'TX was not built');
        assert(~isempty(TW),      'TW was not built');
        assert(~isempty(Receive), 'Receive was not built');
        assert(numel(TX) == double(ReceiveSpec.nTransmissions), ...
               'TX has %d entries but nTransmissions is %d', ...
               numel(TX), double(ReceiveSpec.nTransmissions));

        % --- Verasonics structures -> EchoFrame specs
        fprintf('  vsx_to_ef_structs ...\n');
        [ProbeSpec, TransmitSpec, ReceiveSpec] = ...
            vsx_to_ef_structs(Resource, Trans, TX, Receive, ...
                              ProbeSpec, TransmitSpec, ReceiveSpec);

        fprintf('  initialize_image_reconstruction ...\n');
        ReconSpec.bfDataType        = 'complex single';
        ReconSpec.filterFrequencies = logical(false);
        ReconSpec.getBF             = logical(true);
        ReconSpec.getPDI            = logical(true);
        ReconSpec.cropBF            = logical(false);
        ReconSpec.croppingROI       = [0; 128; 0; 128];   % [zTop; zBottom; xLeft; xRight]
        [ProbeSpec, ReceiveSpec, ReconSpec] = ...
            initialize_image_reconstruction(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec);

        assert(numel(ReconSpec.zAxis) == double(ReconSpec.nz), ...
               'zAxis has %d entries, nz is %d', ...
               numel(ReconSpec.zAxis), double(ReconSpec.nz));
        assert(numel(ReconSpec.xAxis) == double(ReconSpec.nx), ...
               'xAxis has %d entries, nx is %d', ...
               numel(ReconSpec.xAxis), double(ReconSpec.nx));
        fprintf('  grid: %d x %d\n', double(ReconSpec.nz), double(ReconSpec.nx));

        % The specs must survive validation, or the live run would fail at init.
        PDISpec.ensembleSize = ReceiveSpec.nRepeats;
        PDISpec.threshold    = single(0.4);
        PDISpec.shiftSize    = ReceiveSpec.nRepeats;
        PDISpec.cropPDI      = logical(false);
        PDISpec.svdMethod    = 'Covariance';
        fprintf('  echoframe_validate_structs ...\n');
        echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec);

        % --- the live display
        fprintf('  setup_echoframe_figure ...\n');
        setup_echoframe_figure

        % It publishes the two image handles ef_external_process updates each
        % frame; without them the live display would silently never refresh.
        assert(exist('bmode_im', 'var') == 1, 'bmode_im was not published');
        assert(exist('pdi_im',   'var') == 1, 'pdi_im was not published');
        assert(isgraphics(bmode_im, 'image'), 'bmode_im is not an image handle');
        assert(isgraphics(pdi_im,   'image'), 'pdi_im is not an image handle');

        ef_results(ef_p).ok = true;
        fprintf('---- %s OK\n', ef_probes{ef_p});
    catch ef_err
        ef_results(ef_p).ok  = false;
        ef_results(ef_p).msg = ef_err.message;
        fprintf(2, '---- %s FAILED: %s\n', ef_probes{ef_p}, ef_err.message);
    end
    close all
end

%% --------------------------------------------------------------- summary
fprintf('\n==== verify_verasonics_setup summary ====\n');
for ef_p = 1:numel(ef_results)
    if ef_results(ef_p).ok
        fprintf('  PASS  %s\n', ef_results(ef_p).probe);
    else
        fprintf(2, '  FAIL  %s : %s\n', ef_results(ef_p).probe, ef_results(ef_p).msg);
    end
end

if sum(~[ef_results.ok]) > 0
    error('verify_verasonics_setup:failed', ...
          '%d of %d probe setups failed - see the summary above.', ...
          sum(~[ef_results.ok]), numel(ef_results));
end
fprintf('==== ALL PROBE SETUPS PASSED ====\n');
