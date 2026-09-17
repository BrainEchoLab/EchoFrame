function [ProbeSpec, TransmitSpec, ReceiveSpec] = vsx_to_ef_structs(Resource,Trans,TX,Receive,ProbeSpec,TransmitSpec,ReceiveSpec)
%VSX_TO_EF_STRUCTS  Translate the Verasonics structures into EchoFrame specs.
% Called by the Verasonics acquisition-start scripts (e.g. echoframe_acquisition_start.m).
%
%  [ProbeSpec, TransmitSpec, ReceiveSpec] = VSX_TO_EF_STRUCTS(Resource, Trans, TX, Receive, ProbeSpec, TransmitSpec, ReceiveSpec)
%  reads the Verasonics globals and returns the three acquisition specs. The
%  spec arguments are passed in so a probe setup script can fill in whatever it
%  already knows.
%
%  ProbeSpec and TransmitSpec are overwritten: element geometry from
%  Trans.ElementPos, pitch from Trans.spacingMm, Fc from Trans.frequency,
%  steering angles and transmit delays from TX, c0 from
%  Resource.Parameters.speedOfSound.
%
%  ReceiveSpec is filled in only where a field is absent -- every assignment is
%  guarded by isfield -- so values a setup script already computed are kept and
%  only the gaps are taken from the Verasonics structures.
%
%  Trans.Connector becomes channel2ElementMap, shifted to 0-based for C++.
%
%  Only for Verasonics acquisitions. The simulation examples build the specs
%  directly and never call this.
%
%  See also GET_SYSTEM_PARAMETERS, INITIALIZE_IMAGE_RECONSTRUCTION.

%% ProbeSpec
ProbeSpec.nElements       = Trans.numelements;
ProbeSpec.pitch           = Trans.spacingMm / 1e3;  % distance between the transducers in x-direction [m]
ProbeSpec.Fc               = Trans.frequency * 1e6;  % center frequency of the transducers [Hz]
ProbeSpec.elementPosition = Trans.ElementPos; % in mm

%% TransmitSpec
steer = [TX.Steer] * 180 / pi;
% From wavelengths to seconds
transmitDelays = [TX(:).Delay] / (Trans.frequency * 1e6);
transmitDelays = reshape(transmitDelays,ProbeSpec.nElements,1,length(TX));

TransmitSpec.c0            = Resource.Parameters.speedOfSound;
TransmitSpec.type          = 'planewave';
TransmitSpec.steer        = steer(1:2:end);
TransmitSpec.apodization   = TX(1).Apod';
TransmitSpec.transmitDelays = transmitDelays;
TransmitSpec.nTransmission = length(TX);% Number of independent transmissions that will be used to produce one BF frame

%% ReceiveSpec
if isfield(ReceiveSpec,'nSamples') == 0
    ReceiveSpec.nSamples                  = Receive(1).endSample; % Number of samples recorded after the transmission. We call this fast time.
end

if isfield(ReceiveSpec,'nSamplesIQ') == 0
    ReceiveSpec.nSamplesIQ                = ReceiveSpec.nSamples / 2;   % Number of samples divided by 2 which accounts of the number of iq samples.
end

if isfield(ReceiveSpec,'nTransmissions') == 0
    ReceiveSpec.nTransmissions            = length(TX); % Number of independent transmissions that will be used to produce one BF frame
end

if isfield(ReceiveSpec,'samplingMode') == 0
    ReceiveSpec.samplingMode             = Receive(1).sampleMode;
end

if isfield(ReceiveSpec,'nRepeats') == 0
    ReceiveSpec.nRepeats                  = Receive(end).framenum; % Number of repeated transmissions. We call this slow time or Doppler time
end

if isfield(ReceiveSpec,'nChannels') == 0
    ReceiveSpec.nChannels                 = Resource.RcvBuffer.colsPerFrame; % Number of channels of the Verasonics buffer (2nd dimension)
end

if isfield(ReceiveSpec,'channel2ElementMap') == 0
    ReceiveSpec.channel2ElementMap        = Trans.Connector - 1; %
end

if isfield(ReceiveSpec,'Fs') == 0
    ReceiveSpec.Fs                       = Receive(1).decimSampleRate * 1e6;
end

if isfield(ReceiveSpec,'nBuffers') == 0
    ReceiveSpec.nBuffers                  = max([Receive(:).bufnum]);
end

if isfield(ReceiveSpec,'samplesPerWavelength') == 0
    ReceiveSpec.samplesPerWavelength    = Receive(1).samplesPerWave;
end

wvc0        = (Trans.frequency * 1e6 / Resource.Parameters.speedOfSound ) * ReceiveSpec.samplesPerWavelength;

if isfield(ReceiveSpec,'startDepthMm') == 0
    ReceiveSpec.startDepthMm = Receive(1).startDepth / wvc0 * 1e3;
end

if isfield(ReceiveSpec,'actualEndDepthMm') == 0
    ReceiveSpec.actualEndDepthMm = Receive(1).endDepth / wvc0 * 1e3;
end