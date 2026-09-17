function [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = echoframe_validate_structs(ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec)
%ECHOFRAME_VALIDATE_STRUCTS  Fill in derived spec fields and cast to the types C++ expects.
% Called by the acquisition/processing scripts after the specs are built (e.g.
% echoframe_acquisition_start.m, generate_echoframe_demo_data.m).
%
%  [ProbeSpec, TransmitSpec, ReceiveSpec, ReconSpec, PDISpec] = ECHOFRAME_VALIDATE_STRUCTS(...)
%  is the last step before echoframe_mex('init', ...). It does two things.
%
%  First it derives a ReceiveSpec field that no caller should set by hand:
%
%    nElements   = ProbeSpec.nElements
%
%  Then, for each spec, it checks every expected field is present and non-empty
%  and casts it to the declared type (int32 / single / logical / char). Passing a
%  double where the converter wants int32 is normal and expected -- that is what
%  this pass is for.
%
%  Errors if a field is missing or empty, naming the field and the struct.
%
%  Note: extra fields are ignored. A stale field left on a spec is not reported
%  here; it simply never reaches the core. Do not rely on this function to catch
%  renamed or removed fields.
%
%  See also INITIALIZE_IMAGE_RECONSTRUCTION, which must run first.

%% Derived fields
ReceiveSpec.nElements       = ProbeSpec.nElements;

%% Expected fields for ProbeSpec
expectedProbeSpecFields = {
    'pitch', 'double';
    'Fc', 'single';
    'nElements', 'int32';
    'elementPosition', 'single';
    };

%% Expected fields for TransmitSpec
expectedTransmitSpecFields = {
    'c0', 'double';
    'type', 'char';
    'steer', 'single';
    'apodization', 'double';
    'transmitDelays', 'double';
    };

%% Expected fields for ReceiveSpec
expectedReceiveSpecFields = {
    'nSamples', 'int32';
    'nSamplesIQ', 'int32';
    'nTransmissions', 'int32';
    'nRepeats', 'int32';
    'nChannels', 'int32';
    'channel2ElementMap', 'int32';
    'nElements', 'int32';
    'Fs', 'single';
    'samplingMode', 'char';
    'samplesPerWavelength', 'int32'
    };

%% Expected fields for ReconSpec
expectedReconSpecFields = {
    'bfDataType', 'char';
    'getBF', 'logical';
    'getPDI', 'logical';
    'nz', 'int32';
    'nx', 'int32';
    'filterFrequencies', 'logical';
    'cropBF', 'logical';
    'croppingROI', 'int32';
    'extraVoxelsZ', 'int32';
    'extraVoxelsX', 'int32';
    'c0', 'single';
    'tgcVector', 'single';
    'delayIndices', 'int32';
    'interpolationWeights', 'single';
    'frequencyAxis', 'single';
    'planewaveDelays', 'single'; % Size = [TransmitSpec.nTransmissions,2]
    'xAxis', 'double';
    'zAxis', 'double'
    };

%% Expected fields for PDISpec
expectedPDISpecFields = {
    'ensembleSize', 'int32';
    'threshold', 'single';
    'shiftSize', 'int32';
    'cropPDI', 'logical';
    'svdMethod', 'char'
    };

%% Validate and cast ProbeSpec
ProbeSpec = validate_and_cast(ProbeSpec, expectedProbeSpecFields, 'ProbeSpec');

%% Validate and cast TransmitSpec
TransmitSpec = validate_and_cast(TransmitSpec, expectedTransmitSpecFields, 'TransmitSpec');

%% Validate and cast ReceiveSpec
ReceiveSpec = validate_and_cast(ReceiveSpec, expectedReceiveSpecFields, 'ReceiveSpec');

%% Validate and cast ReconSpec
ReconSpec = validate_and_cast(ReconSpec, expectedReconSpecFields, 'ReconSpec');

%% Validate and cast PDISpec
PDISpec = validate_and_cast(PDISpec, expectedPDISpecFields, 'PDISpec');

end

function structOut = validate_and_cast(structIn, expectedFields, structName)
% Validate fields in the structure and ensure they are the correct type
for i = 1:size(expectedFields, 1)
    fieldName = expectedFields{i, 1};
    expectedType = expectedFields{i, 2};
    
    if ~isfield(structIn, fieldName)
        error(['Field "', fieldName, '" is missing from ', structName]);
    else
        fieldValue = structIn.(fieldName);
        
        % Check if the field is uninitialized or empty
        if isempty(fieldValue)
            error(['Field "', fieldName, '" in ', structName, ' is not initialized!']);
        end
        
        % Cast correct type
        if ~isa(fieldValue, expectedType)
            %             disp(['Casting field "', fieldName, '" in ', structName, ' to ', expectedType]);
            structIn.(fieldName) = cast_field(fieldValue, expectedType);
        end
    end
end
structOut = structIn;
end

function valueOut = cast_field(valueIn, expectedType)
% Perform casting based on the expected type
switch expectedType
    case 'int32'
        valueOut = int32(valueIn);
    case 'single'
        valueOut = single(valueIn);
    case 'logical'
        valueOut = logical(valueIn);
    case 'char'
        valueOut = char(valueIn);
    otherwise
        error(['Unknown type: ', expectedType]);
end
end
