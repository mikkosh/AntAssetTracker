/**
 * AntAssetTracker ConnectIQ module for communicating with devices supporting
 * Ant Asset Tracker profile such as Garmin Astro or other Dog trackers.
 * 
 * MIT License
 * 
 * Copyright (c) 2018 Mikko Hämäläinen
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * @todo: add required support for tracking multiple assets
 * @todo: add support for parsing asset status byte
 */
using Toybox.Ant;
using Toybox.Math;
using Toybox.StringUtil;

/**
 * AntAssetTracker module
 */
module AntAssetTracker {

	/**
	 * TrackerSensor class
	 */
	class TrackerSensor extends Ant.GenericChannel {
	    
	    const DEVICE_TYPE = 41; // type: asset tracker
	    const PERIOD = 2048;
	    const DEVICE_RF = 57; // frequency
	
	    hidden var chanAssign;
	
	    var data;
	    var searching;
	    var deviceCfg;
	    
	    var locationParser;
		var identifionParser;
		
	    function initialize() {
	
	        // Get the channel
	        chanAssign = new Ant.ChannelAssignment(
	            Ant.CHANNEL_TYPE_RX_NOT_TX,
	            Ant.NETWORK_PLUS);
	        GenericChannel.initialize(method(:onMessage), chanAssign);
	
	        // Set the configuration
	        deviceCfg = new Ant.DeviceConfig( {
	            :deviceNumber => 0, // wildcard search                
	            :deviceType => DEVICE_TYPE,
	            :transmissionType => 0,
	            :messagePeriod => PERIOD,
	            :radioFrequency => DEVICE_RF,
	            :searchTimeoutLowPriority => 10,    
	            :searchThreshold => 0} );           
	        GenericChannel.setDeviceConfig(deviceCfg);
	
			locationParser = new AssetLocationParser();
			identifionParser = new AssetIdentificationParser();
			
	        data = new AssetData();
	        searching = true;
	        
	    }
	
	    function open() {
	        
	        GenericChannel.open();
	        data = new AssetData();
	        searching = true;
	    }
	
	    function closeSensor() {
	        GenericChannel.close();
	    }
	
	    /**
	     * Sends request for asset identification page
	     */
	    function requestAssetIdentification() {
	    	var payload = new [8];
	        payload[0] = 0x46;  
	        payload[1] = 0xFF;  
	        payload[2] = 0xFF;
	        payload[3] = 0xFF;
	        payload[4] = 0xFF;
	        payload[5] = 0x04;
	        payload[6] = 0x10;
	        payload[7] = 0x04;
	        var message = new Ant.Message();
	        message.setPayload(payload);
	        GenericChannel.sendAcknowledge(message);
	    }
	
	    function onMessage(msg) {
	        
	        var payload = msg.getPayload();
	        
	        if( Ant.MSG_ID_BROADCAST_DATA == msg.messageId ) {
	        	var pageNumber = (payload[0].toNumber() & 0xFF);
	        	
	        	// In search state, now we found something
	            if (searching) {
	                searching = false;
	                // request asset identification to get tracker names etc.
	                requestAssetIdentification();
	                // Update our device configuration primarily to see the device number of the sensor we paired to
	                //deviceCfg = GenericChannel.getDeviceConfig();
	            }
	            // check if location parser can handle the page
	            if( locationParser.canProcess(pageNumber)) {
	                
	                // add page to the parser
	                locationParser.addPage(pageNumber, payload);
	                
	                // have all pages been received, then we're good to parse the data
	                if(locationParser.canParse) {
	                	// update data
	                	locationParser.parse(data);
	                }
	            } else if( identifionParser.canProcess(pageNumber)) {
	            	// add page to parser
	            	identifionParser.addPage(pageNumber, payload);
	            	
	            	// got all pages?
	                if(identifionParser.canParse) {
	                	// parse and update data
	                	identifionParser.parse(data);
	                }
	            }
	            
	        } else if(Ant.MSG_ID_CHANNEL_RESPONSE_EVENT == msg.messageId) {
	            if (Ant.MSG_ID_RF_EVENT == (payload[0] & 0xFF)) {
	                if (Ant.MSG_CODE_EVENT_CHANNEL_CLOSED == (payload[1] & 0xFF)) {
	                    // Channel closed, re-open
	                    open();
	                } else if( Ant.MSG_CODE_EVENT_RX_FAIL_GO_TO_SEARCH  == (payload[1] & 0xFF) ) {
	                    searching = true;
	                }
	            } else {
	                //It is a channel response.
	            }
	        }
	    }
	}
	/**
	 * AssetData class contains data for single asset
	 */
	class AssetData {
        var index;
        var distance;
        var bearingDeg;
        var situation;
        var isLowBattery;
        var isGPSLost;
        var isCommLost;
        var shouldRemove;
        var latitude;
        var longitude;
        
        var color;
        var type;
        var name;

        function initialize() {
            index = 0;
            distance = 0;
            bearingDeg = 0;
            situation = 4; // Unknown
           
            isLowBattery = false;
            isGPSLost = false;
            isCommLost = false;
            shouldRemove = false;
            
            latitude = 0;
            longitude = 0;
            
            color = 0;
            type = 0;
            name = "";
        }
    }
	/**
	 * AssetLocationParser for parsing asset location pages 1 & 2
	 */
    class AssetLocationParser {
    
        static const PAGE_NUMBER_FIRST = 1;
        static const PAGE_NUMBER_SECOND = 2;
        
        var currentAssetIndex = null;
        var canParse = false;
        
        var firstPagePayload = null;
        var secondPagePayload = null;
        
        function canProcess(pageNro) {
        	if (pageNro == PAGE_NUMBER_FIRST || pageNro == PAGE_NUMBER_SECOND) {
        		if(pageNro == PAGE_NUMBER_FIRST) {
        			reset();
        			return true;
    			}
    			
				if(pageNro == PAGE_NUMBER_SECOND && firstPagePayload != null) {
        			return true;
        		}
        	}
        	return false;
        }
        function reset() {
        	firstPagePayload = null;
        	secondPagePayload = null;
        	currentAssetIndex = null;
        	canParse = false;
        }
        
        function addPage(pageNro, payload) {
        	var aIdx = parseAssetIndex(payload);
        	if(pageNro == PAGE_NUMBER_FIRST) {
        		reset();
        		currentAssetIndex = aIdx;
        		firstPagePayload = payload;
        	} else { // second page
        		if(aIdx == currentAssetIndex) {
        			secondPagePayload = payload;
        			canParse = true;
        		} else {
        			// mismatach
        			reset();
        			return false;
        		}
        	}
        	return true;
        }
        
        function parseAssetIndex(payload) {
        	return payload[1] & 0x1F;
        }
        
        function parseDistance(payload) {
        	return ((payload[2]) | (payload[3] << 8));
        }
        
        function parseBearing(payload) {
        	var bearingBrad = payload[4];
        	return (1.0 * bearingBrad / 256) * 360;
        }
        
        function convertSemicircleToDeg(semicircle) {
        	return (1.0 * semicircle / Math.pow(2,31)) * 180;
        }
        function parseLatitude(payloadFirst, payloadSecond) {
        	var latSemicircle; 
        	latSemicircle = (payloadFirst[6] | (payloadFirst[7] << 8) | (payloadSecond[2] << 16) | (payloadSecond[3] << 24));
        	return convertSemicircleToDeg(latSemicircle);
        }
        function parseLongitude(payload) {
        	var lonSemicircle; 
        	lonSemicircle = (payload[4] | (payload[5] << 8) | (payload[6] << 16) | (payload[7] << 24));
        	return convertSemicircleToDeg(lonSemicircle);
        }
        
        function parse(data) {
        	data.index = parseAssetIndex(firstPagePayload);
        	data.distance = parseDistance(firstPagePayload);
        	data.bearingDeg = parseBearing(firstPagePayload);
        	data.latitude = parseLatitude(firstPagePayload, secondPagePayload);
        	data.longitude = parseLongitude(secondPagePayload);
        }
    }
    /**
	 * AssetIdentificationParser for parsing asset identification pages 16 & 17
	 */
    class AssetIdentificationParser {
    
        static const PAGE_NUMBER_FIRST = 0x10; // 16
        static const PAGE_NUMBER_SECOND = 0x11; //17
        
        var currentAssetIndex = null;
        var canParse = false;
        
        var firstPagePayload = null;
        var secondPagePayload = null;
        
        function canProcess(pageNro) {
        	if (pageNro == PAGE_NUMBER_FIRST || pageNro == PAGE_NUMBER_SECOND) {
        		if(pageNro == PAGE_NUMBER_FIRST) {
        			reset();
        			return true;
    			}
    			
				if(pageNro == PAGE_NUMBER_SECOND && firstPagePayload != null) {
        			return true;
        		}
        	}
        	return false;
        }
        function reset() {
        	firstPagePayload = null;
        	secondPagePayload = null;
        	currentAssetIndex = null;
        	canParse = false;
        }
        
        function addPage(pageNro, payload) {
        	var aIdx = parseAssetIndex(payload);
        	if(pageNro == PAGE_NUMBER_FIRST) {
        		reset();
        		currentAssetIndex = aIdx;
        		firstPagePayload = payload;
        	} else { // second page
        		if(aIdx == currentAssetIndex) {
        			secondPagePayload = payload;
        			canParse = true;
        		} else {
        			// mismatach
        			reset();
        			return false;
        		}
        	}
        	return true;
        	
        }
        
        function parseAssetIndex(payload) {
        	return payload[1] & 0x1F;
        }
        
        function parseColor(payload) {
        	return payload[2];
        }
        
        function parseType(payload) {
        	return payload[2];
        }
        
       
        function parseName(payloadFirst, payloadSecond) {
        	
			var nameArr = new [10];
        	for(var i=3; i<8; i++) {
        		nameArr[i-3] = payloadFirst[i];
        	}
        	
        	for(var i=3; i<8; i++) {
        		nameArr[i+2] = payloadSecond[i];
        	}
        	return StringUtil.utf8ArrayToString(nameArr);
        }
       
        
        function parse(data) {
        	data.color = parseColor(firstPagePayload);
        	data.type = parseType(secondPagePayload);
        	data.name = parseName(firstPagePayload, secondPagePayload);
        }
		
    }
}
