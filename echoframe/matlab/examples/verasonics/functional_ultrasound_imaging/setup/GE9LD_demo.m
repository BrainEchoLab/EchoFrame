% GE9LD_demo - Plane-wave acquisition setup for the GE 9LD probe.
%
% Configures Verasonics structures (Trans, TX, TW, Receive, TGC, Process,
% SeqControl, Event) and the EchoFrame ProbeSpec / TransmitSpec / ReceiveSpec /
% ReconSpec parameters for high-frame-rate plane-wave Doppler imaging with the
% GE 9LD probe.
%
% Called by echoframe_acquisition_start.m.

global TX TW Trans Receive Resource absoluteTime          % Verasonics variables
global ProbeSpec TransmitSpec ReceiveSpec ReconSpec       % EchoFrame variables

%% GUI Base Verasonics
assignin('base', 'TX', TX);
assignin('base', 'TW', TW);
assignin('base', 'Trans', Trans);
assignin('base', 'Receive', Receive);
assignin('base', 'Resource', Resource);
assignin('base', 'absoluteTime', absoluteTime);

%% GUI Base EchoFrame
assignin('base', 'ReconSpec', ReconSpec);
assignin('base', 'ReceiveSpec', ReceiveSpec);
assignin('base', 'TransmitSpec', TransmitSpec);

%% Acquisition Parameters 1 - Affecting acoustic safety | DO NOT CHANGE
TransmitSpec.txrxFrameRate       = 8e3;    % Acquisition frame rate before angle compounding [Hz]
TransmitSpec.transmitPulseLength = 3;       % pulse length in half cycles of Doppler Pulse
Trans.frequency             	 = 5.2083;  % 62.5/x, x being integer 5,6,7,....
Trans.numelements                = 192;
TransmitSpec.aperturePercentage  = 80;
ReceiveSpec.aperturePercentage   = 90;
TransmitSpec.apodization         = calculate_transmit_apodization(Trans.numelements,TransmitSpec.aperturePercentage);
ReceiveSpec.apodization          = calculate_receive_apodization(Trans.numelements,ReceiveSpec.aperturePercentage);
Trans.maxHighVoltage             = 15; % conservative value, max. voltage not known

%% Acquisition Parameters 2 - Not affecting acoustic safety
% These three together set the data rate: run report_storage_demand before an
% acquisition to see what they ask of the drive.
ReceiveSpec.samplingMode           = 'BS100BW'; % 'BS50BW' halves the samples per wavelength
ReceiveSpec.startDepthMm           = 0;      % start depth for imaging [mm] (TODO: nonzero start depth not supported yet)
ReceiveSpec.desiredEndDepthMm      = 80;     % Imaging depth in [mm]
ReceiveSpec.nTransmissions         = 10;     % Number of angles for Doppler (even number preferred)
ReceiveSpec.nRepeats               = 200;    % Ensemble raw_data_size is used to compute the Power Doppler Image
TransmitSpec.planewaveOpeningAngle = 12;     % Total angle opening for the steered plane waves [degrees]
TransmitSpec.c0                    = 1540;   % Speed of sound [m/s] assumption that is used for the reconstruction. This number can be changed also in the GUI
ReceiveSpec.tgcGain                = 900;

%% Image Reconstruction Parameters 1 - Not affecting acoustic safety
ReconSpec.extraVoxelsZ           = 0;    % Extra voxels for more detailed images | Should idealy be a power of two
ReconSpec.extraVoxelsX           = 0;    % Extra voxels for more detailed images | Should idealy be a power of two
ReconSpec.svdRejectHighPercentage = 40;    % Percentage of singular vectors from the tissue subspace that is removed to obtain the vascularity signals
ReconSpec.svdRejectLowPercentage  = 1;     % Percentage of singular vectors from the noise subspace that is removed
ReconSpec.c0                     = TransmitSpec.c0; % Speed of sound is first used to calculate the planewave angles but may be changed later in the reconstruction process

%% System Recieve Parameters
RcvProfile.LnaZinSel             = 29;    % To get a first order highpass filter of 20MHz when = 0. 31 for highpass filter of
RcvProfile.AntiAliasCutoff       = 20;
RcvProfile.LnaGain               = 15;    % Possible values 15, 18, and 24 [dB]
RcvProfile.PgaGain               = 30;    % Possible values 24 and 30 [dB]

%% Probe - Setup
Trans.name                       = 'GE9LD' ;
Trans.id                         = hex2dec('270212');
Trans.units                      = 'mm';
Trans.Bandwidth                  = Trans.frequency*[1-.4, 1+.4];  % 80% relative bandwidth
Trans.type                       = 0;     %linear array
Trans.connType                   = 7; % =7 GE connector
Trans.spacingMm                  = .230; % spacing in mm.
Trans.elementWidth               = 0.9 * Trans.spacingMm; % width in mm (guess)
Trans.elevationApertureMm        = 6.0; % active elevation aperture in mm
Trans.elevationFocusMm           = 40; % nominal elevation focus depth from lens on face of transducer (estimate)
Trans.ElementPos                 = zeros(Trans.numelements,5);% Set default element positions (units in mm).
Trans.ElementPos(:,1)            = Trans.spacingMm*(-((Trans.numelements-1)/2):((Trans.numelements-1)/2));
Trans.lensCorrection             = .5; % in mm units; (guess)
Trans.impedance                  = 50;% value is set low - needs to be measured before using in profile 5
ProbeSpec.Fc                     = Trans.frequency * 1e6;
scaleToWvl                       = Trans.frequency/(TransmitSpec.c0/1e3);
Theta                            = (-pi/2:pi/100:pi/2);
Theta(51)                        = 0.0000001;
eleWidthWl                       = Trans.elementWidth * scaleToWvl;
Trans.ElementSens                = abs(cos(Theta));
ProbeSpec.pitch                  = Trans.spacingMm * 1e-3; % assign Transducer pitch in meters

% Get Trans.Connector here instead of during VSX
Trans.ConnectorES                = (33:224)';
Trans.Connector =  ...
[  120   121   116   122   115   123   114   124   113   125   119   126   118   127   117   128   181   192   182   191   183   190   184   189   165   188   166   187   167   186   172   185    33,...
    44    34    43    35    42    36    41    37    48    38    47    39    46    40    45   241   245   242   246   243   247   244   248   228   229   227   230   226   231   225   232    49    57,...
    51    58    53    59    55    61    50    63    52    60    54    62    56    64   236   240   235   239   234   238   233   237   252   256   251   255   250   254   249   253     8    12     7,...
    11     6    10     5     9     4    16     3    15     2    14     1    13   205   197   206   198   193   199   194   200   195   209   196   210   207   211   208   212    17    28    18    27,...
    19    26    20    25    21    32    22    31    23    30    24    29   216   224   215   223   214   222   213   221   204   217   203   218   202   219   201   220    83    84    82    85    81,...
    86    80    87    68    69    67    70    66    71    65    72   145   152   146   151   147   150   148   149   129   136   130   135   131   134   132   133];


%% Additional Parameters (do not change)
% Acquisition ring depth. Also caps the RF write queue (init_storage), since RF
% is written straight out of this ring: the hardware may reuse a frame after
% nBuffers frames, so the queue must not hold more than that. Minimum is 2; 1
% deadlocks the transfer handshake. Costs one RF frame of host memory per slot.
ReceiveSpec.nBuffers                 = 4;
ReceiveSpec.transmitReceiveTimeMus   = round( 1e6 / TransmitSpec.txrxFrameRate );
ReceiveSpec.dopplerSamplingFrequency = TransmitSpec.txrxFrameRate / ReceiveSpec.nTransmissions;
ReceiveSpec.acquisitionTime          = ReceiveSpec.transmitReceiveTimeMus * ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats * 1e-6;
ReceiveSpec.triggerOverheadTime      = 1e-3;
ReceiveSpec.pdiTriggerTime           = ceil((ReceiveSpec.acquisitionTime + ReceiveSpec.triggerOverheadTime) * 1e3);
ReceiveSpec.requiredProcessingTime   = (ReceiveSpec.nRepeats * ReceiveSpec.nTransmissions) / TransmitSpec.txrxFrameRate;

%% Get System Parameters
[Resource, Trans, TransmitSpec, ReceiveSpec] = get_system_parameters(Resource, Trans, TransmitSpec, ReceiveSpec);

%% Transmit
TW(1).type = 'parametric';
TW(1).Parameters = [ProbeSpec.Fc*1e-6, 0.67, TransmitSpec.transmitPulseLength, 1];   % A, B, C, D

% Specify TX structure array.
TX = repmat(struct('waveform', 1, ...
    'Origin', [0.0,0.0,0.0], ...
    'focus', 0.0, ...
    'Steer', [0.0,0.0], ...
    'Apod', TransmitSpec.apodization, ...
    'Delay', zeros(1,Resource.Parameters.numTransmit)), 1, ReceiveSpec.nTransmissions);

dthetaDop = (TransmitSpec.planewaveOpeningAngle*pi/180)/(ReceiveSpec.nTransmissions-1);
startAngleDop = - TransmitSpec.planewaveOpeningAngle * pi / 180 / 2;

for n = 1:ReceiveSpec.nTransmissions
    TX(n).Steer = [(startAngleDop+(n-1)*dthetaDop),0.0];
    TX(n).Delay = computeTXDelays(TX(n));
end

%% Buffer allocation
wvc0                                = ( Trans.frequency * 1e6 / Resource.Parameters.speedOfSound ) * ReceiveSpec.samplesPerWavelength;
start_size                          = ReceiveSpec.startDepthMm * 1e-3 * wvc0;
depth_size                          = ReceiveSpec.desiredEndDepthMm * 1e-3 * wvc0;
maxAcqLngth                         = depth_size - start_size;
ReceiveSpec.nSamples                = ceil( maxAcqLngth / 64 ) * 64 * 2;   % Only multiples of 128 are allwed in the memory so end depth will change
ReceiveSpec.nSamplesIQ              = ReceiveSpec.nSamples / 2;
Resource.RcvBuffer(1).rowsPerFrame  = ReceiveSpec.nSamples * ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats;
% Ring depth (set by get_system_parameters) and the host memory it costs.
if isfield(Resource.Parameters, 'numRcvChannels')
    rcvChannels = Resource.Parameters.numRcvChannels;
else
    rcvChannels = Trans.numelements;   % receive on every element
end
fprintf(['RcvBuffer(1): numFrames=%d, rowsPerFrame=%d, %d channels -> ' ...
         '%.2f GB/frame, %.2f GB total\n'], ...
        Resource.RcvBuffer(1).numFrames, Resource.RcvBuffer(1).rowsPerFrame, ...
        rcvChannels, ...
        Resource.RcvBuffer(1).rowsPerFrame * rcvChannels * 2 / 2^30, ...
        Resource.RcvBuffer(1).numFrames * Resource.RcvBuffer(1).rowsPerFrame * ...
        rcvChannels * 2 / 2^30);
clear rcvChannels
ReceiveSpec.actualEndDepthMm        = (ReceiveSpec.nSamples / wvc0 * 1e3) / 2 + ReceiveSpec.startDepthMm;
ReceiveSpec.startDepthWavelengths   = ReceiveSpec.startDepthMm * 1e-3      * Trans.frequency * 1e6 / Resource.Parameters.speedOfSound; % In wavelengths
ReceiveSpec.endDepthWavelengths     = ReceiveSpec.actualEndDepthMm * 1e-3 * Trans.frequency * 1e6 / Resource.Parameters.speedOfSound; % In wavelengths
ReceiveSpec.lensOffset              = Trans.lensCorrection * 4 * ReceiveSpec.samplesPerWavelength;

%% Set up  Receive gain, Receive structure
Receive = repmat(struct('startDepth', ReceiveSpec.lensOffset + ReceiveSpec.startDepthWavelengths, ...
    'endDepth'  , ReceiveSpec.lensOffset + ReceiveSpec.endDepthWavelengths, ...
    'TGC', 1, ...
    'bufnum', 1, ...
    'framenum', 1, ...
    'acqNum', 1, ...
    'sampleMode', ReceiveSpec.samplingMode, ...
    'demodFrequency', Trans.frequency, ...
    'mode', 0, ...
    'callMediaFunc', 0), 1, ReceiveSpec.nRepeats * ReceiveSpec.nTransmissions * ReceiveSpec.nBuffers);

% - Set event specific Receive attributes.
for iFrame = 1:ReceiveSpec.nBuffers
    k = ReceiveSpec.nRepeats * ReceiveSpec.nTransmissions  * ( iFrame - 1 ); % k keeps track of Receive index increment per frame.
    Receive(k+1).callMediaFunc = 1;
    for i = 1:ReceiveSpec.nTransmissions * ReceiveSpec.nRepeats
        Receive(i+k).Apod = ReceiveSpec.apodization;
        Receive(i+k).TGC = 1;
        Receive(i+k).framenum =  iFrame;
        Receive(i+k).acqNum = i;
    end
end

%% TGC
TGC(1).CntrlPts = [1,1,1,1,1,1,1,1] .* ReceiveSpec.tgcGain;
TGC(1).rangeMax = ReceiveSpec.endDepthWavelengths;
TGC(1).Waveform = computeTGCWaveform(TGC(1));

% TGC vector that mutes the transmission for the Fourier code.
temp_kernel =  gausswin(20,5)'; %ones(1,15)./15;
zeros_samples_start = zeros(1,round(10 * ReceiveSpec.samplesPerWavelength));
zeros_samples_end = zeros(1,round(3 * ReceiveSpec.samplesPerWavelength));
tcg = ones(1,ReceiveSpec.nSamplesIQ - length(zeros_samples_start) - length(zeros_samples_end));
ReconSpec.tgcVector = convn([zeros_samples_start tcg zeros_samples_end],temp_kernel,'same');

%% Processing Functions
Process(1).classname = 'External';
Process(1).method = 'ef_external_process';
Process(1).Parameters = {'srcbuffer','receive',...  % name of buffer to process.
    'srcbufnum',1,...
    'srcframenum', -1,...
    'dstbuffer','none'};

%% SeqControl structure arrays.
SeqControl(1).command  = 'timeToNextAcq';
SeqControl(1).argument = ReceiveSpec.transmitReceiveTimeMus;% PRF for Doppler ensemble
SeqControl(2).command = 'triggerOut'; % Trigger out
SeqControl(3).command  = 'jump';% -- Jump back to start.
SeqControl(3).argument = 1;
SeqControl(4).command = 'returnToMatlab'; % Return to Matlab
SeqControl(5).command   = 'pause';
SeqControl(5).condition = 'extTrigger'; % input BNC #1 falling edge
SeqControl(5).argument  = 1;
nsc = 6;

last_transfer_nsc = 0;
%% Event structure arrays.
n = 1;
for iFrame = 1:ReceiveSpec.nBuffers
    for iRepeat = 1:ReceiveSpec.nRepeats
        for iTransmit = 1:ReceiveSpec.nTransmissions
            Event(n).info = 'LongEnsembleAquisition';
            Event(n).tx = iTransmit;        % use next TX structures after 2D.
            Event(n).rcv = (iFrame-1) * ReceiveSpec.nRepeats * ReceiveSpec.nTransmissions + (iRepeat-1) * ReceiveSpec.nTransmissions + iTransmit;
            Event(n).recon = 0;             % no reconstruction.
            Event(n).process = 0;           % no processing
            Event(n).seqControl = [1, 2];
            n = n+1;
        end
    end
    %     INFO.event_counter(iFrame) = n-1;
    SeqControl(nsc).command = 'transferToHost'; % transfer frame to host buffer
    last_transfer_nsc = nsc;

    Event(n-1).seqControl = [1, 2, nsc];
    nsc = nsc+1;

    Event(n).info = 'Beamform';
    Event(n).tx = 0;        % no TX
    Event(n).rcv = 0;       % no Rcv
    Event(n).recon = 0;     % no Recon
    Event(n).process = 1;
    Event(n).seqControl = nsc; % wait for data to be transferred
    SeqControl(nsc).command = 'waitForTransferComplete';
    SeqControl(nsc).argument = last_transfer_nsc;
    nsc = nsc+1;
    n = n+1;

    Event(n).info = 'Reset buffer flag';
    Event(n).tx = 0;        % no TX
    Event(n).rcv = 0;       % no Rcv
    Event(n).recon = 0;     % no Recon
    Event(n).process = 0;
    Event(n).seqControl = [nsc, 4]; % wait for data to be transferred
    SeqControl(nsc).command = 'markTransferProcessed';
    SeqControl(nsc).argument = last_transfer_nsc;
    nsc = nsc+1;
    n = n+1;
end

Event(n).info = 'jump';
Event(n).tx = 0;        % no TX
Event(n).rcv = 0;       % no Rcv
Event(n).recon = 0;     % no Recon
Event(n).process = 0;
Event(n).seqControl = 3;

