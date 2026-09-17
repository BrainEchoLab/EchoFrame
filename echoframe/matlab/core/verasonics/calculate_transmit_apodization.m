function transmit_apodization = calculate_transmit_apodization(number_of_elements,transmit_aperture_percentage)
%CALCULATE_TRANSMIT_APODIZATION  Tukey-windowed transmit apodization vector.
% Called by the Verasonics probe-setup scripts (e.g. GE9LD_demo.m, L74_demo.m).
%
%  APOD = CALCULATE_TRANSMIT_APODIZATION(NUMBER_OF_ELEMENTS, TRANSMIT_APERTURE_PERCENTAGE)
%  returns a 1-by-NUMBER_OF_ELEMENTS vector holding a Tukey window (r = 0.1)
%  over the centred active aperture, and zeros either side of it.
%
%  TRANSMIT_APERTURE_PERCENTAGE is the share of the array left on: 100 uses every
%  element, 80 turns off the outer 20%. The number turned off is rounded up to
%  even so the aperture stays centred.
%
%  Weights of 0.2 and below are forced to zero, working around a Verasonics bug
%  with very small apodization values.
%
%  See also CALCULATE_RECEIVE_APODIZATION, which is the same but tapers wider
%  (r = 0.2).

number_of_elements_off = round(number_of_elements * (100-transmit_aperture_percentage)/100);
number_of_elements_off = number_of_elements_off + rem(number_of_elements_off,2); 
number_of_elements_on  = number_of_elements - number_of_elements_off; 

transmit_apodization   = zeros(1,number_of_elements);
apodization = tukeywin(number_of_elements_on,.1);

transmit_apodization(number_of_elements_off/2 + 1 : end - number_of_elements_off/2)  = apodization;
transmit_apodization(transmit_apodization<=.2) = 0; % Bug in verasonics will be solved with new release
end
