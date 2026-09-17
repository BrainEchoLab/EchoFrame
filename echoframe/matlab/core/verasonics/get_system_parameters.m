function [Resource, Trans, TransmitSpec, ReceiveSpec] = get_system_parameters(Resource, Trans, TransmitSpec, ReceiveSpec)
%GET_SYSTEM_PARAMETERS  Derive system and receive settings from the probe and sampling mode.
% Called by the Verasonics probe-setup scripts, after the acquisition parameters
% are chosen and before the Receive structures are built.
%
%  [Resource, Trans, TransmitSpec, ReceiveSpec] = GET_SYSTEM_PARAMETERS(Resource, Trans, TransmitSpec, ReceiveSpec)
%
%  Sets on Resource::
%
%    Parameters.speedOfSound  from TransmitSpec.c0
%    RcvBuffer(1)             datatype, colsPerFrame, numFrames
%
%  Sets on ReceiveSpec::
%
%    nChannels             128 or 256, from Resource.Parameters.numRcvChannels
%                          and Trans.numelements
%    Fs                    Trans.frequency * 4 (Hz)
%    samplesPerWavelength  from samplingMode: 1 (BS50BW), 4/3 (BS67BW),
%                          2 (BS100BW), 4 (NS200BW)
%
%  Trans and TransmitSpec are returned unchanged; they are inputs only.
%
%  An unrecognised ReceiveSpec.samplingMode prints a message and returns early,
%  leaving samplesPerWavelength unset.
%
%  See also VSX_TO_EF_STRUCTS.

% Specify system parameters.
Resource.Parameters.speedOfSound = TransmitSpec.c0;
Resource.Parameters.speedCorrectionFactor = 1.0;
Resource.Parameters.numLogDataRecs = 128;
% Specify Resources.
Resource.RcvBuffer(1).datatype = 'int16';
Resource.RcvBuffer(1).colsPerFrame = Resource.Parameters.numRcvChannels;
Resource.RcvBuffer(1).numFrames = ReceiveSpec.nBuffers;

switch Resource.Parameters.numRcvChannels
    case 64
        ReceiveSpec.nChannels      = 128;
    case 128
        ReceiveSpec.nChannels      = 128;
    case 256
        if Trans.numelements <= 128
            ReceiveSpec.nChannels  = 128;
        else
            ReceiveSpec.nChannels  = 256;
        end
end

ReceiveSpec.Fs = Trans.frequency * 4 * 1e6;
switch ReceiveSpec.samplingMode
    case 'BS50BW'
        ReceiveSpec.samplesPerWavelength = 1;
    case 'BS67BW'
        ReceiveSpec.samplesPerWavelength = 4/3;
    case 'BS100BW'
        ReceiveSpec.samplesPerWavelength = 2;
    case 'NS200BW'
        ReceiveSpec.samplesPerWavelength = 4;
    otherwise
        disp(['Unknown sample mode specified. Exiting.']);
        return
end