import numpy as np
import matplotlib.pyplot as plt
import h5py
from scipy.linalg import svd

# Define file paths and filenames
load_path = ""
filename = "bf_acq"
filepath = load_path + filename + ".dat"

# Open the data file
fileID = open(filepath, "rb")

# Load the Scan Parameters from the .mat file
scanParametersPath = load_path + "ScanParameters.mat"
with h5py.File(scanParametersPath, 'r') as file:
    ReconSpec = file['ReconSpec']
    ReceiveSpec = file['ReceiveSpec']

    cropBF = bool(np.array(ReconSpec['cropBF'][()])) if 'cropBF' in ReconSpec else False

    if cropBF:
        nz = int(np.array(ReconSpec['croppingROI'][0][1]) - np.array(ReconSpec['croppingROI'][0][0]) + 1)
        nx = int(np.array(ReconSpec['croppingROI'][0][3]) - np.array(ReconSpec['croppingROI'][0][2]) + 1)
    else:
        if ReconSpec['nx'].shape[0] > 1:
            nz = int(np.array(ReconSpec['nx'][0]))
            nx = int(np.array(ReconSpec['nx'][1]))
        else:
            nz = int(np.array(ReconSpec['nz'][()]))
            nx = int(np.array(ReconSpec['nx'][()]))
    nRepeats = int(np.array(ReceiveSpec['nRepeats'][()]))

# Read header information
numHeaderElements = 5
header = np.fromfile(fileID, dtype=np.uint64, count=numHeaderElements)
mVersion, mHeaderSize, mBuffersDequeued, effectiveBufferSize, mPaddingBytes = header

# Move file position to the end of the header
fileID.seek(mHeaderSize)

# Initialize an array to hold the BF frames
BF_frames = np.zeros((nz, nx, nRepeats, mBuffersDequeued), dtype=np.complex64)

# Process data for each buffer
for i in range(mBuffersDequeued):
    print(f"Processing buffer {i + 1}/{mBuffersDequeued}")

    # Read buffer of 'single' (float32) data
    data_chunk_raw = np.fromfile(fileID, dtype=np.float32, count=2 * int(effectiveBufferSize))

    # Convert raw data to complex numbers
    data_chunk_complex = data_chunk_raw[::2] + 1j * data_chunk_raw[1::2]

    # Reshape to (nz, nx, nRepeats) based on crop or full dimensions
    BF = data_chunk_complex.reshape((nz, nx, nRepeats), order='F')

    # Store in the 4D array for all BF frames
    BF_frames[:, :, :, i] = BF

    # Example B-mode image calculation for the current buffer
    Bmode = np.abs(np.mean(BF, axis=2))  # Mean along the repeats dimension
    Bmode = Bmode / np.max(Bmode)  # Normalize
    Bmode_db = 20 * np.log10(Bmode)  # Convert to dB scale

    # # Display the B-mode image
    plt.figure(figsize=(6, 6))
    plt.imshow(Bmode_db, cmap='gray', extent=[0, nx, nz, 0], vmin=-40, vmax=0)
    plt.colorbar(label='dB')
    plt.xlabel('Pixels in x direction')
    plt.ylabel('Pixels in z direction')
    plt.title(f'B-mode image for BF Frame {i + 1}')
    plt.show()

    # Skip padding bytes before moving to the next buffer
    fileID.seek(mPaddingBytes, 1)  # Skip `mPaddingBytes` from the current position

# Close the data file
fileID.close()
