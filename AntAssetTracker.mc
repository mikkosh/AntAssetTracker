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
 * @todo: add support for parsing asset status byte
 */
using Toybox.Ant;
using Toybox.Math;
using Toybox.StringUtil;

/**
 * AntAssetTracker module
 */
module AntAssetTracker {

	const STATUS_SITTING = 0;
	const STATUS_MOVING = 1;
	const STATUS_POINTED = 2;
	const STATUS_TREED = 3;
	const STATUS_UNKNOWN = 4;
	const STATUS_NOT_DEFINED = 0xFF;
	
	const PAGE_LOCATION_FIRST = 0x01;
    const PAGE_LOCATION_SECOND = 0x02;
    const PAGE_IDENTIFICATION_FIRST = 0x10; // 16
    const PAGE_IDENTIFICATION_SECOND = 0x11; //17
	const PAGE_DISCONNECT_CMD = 0x20;
	const PAGE_NO_ASSETS = 0x03;
	const PAGE_REQUEST_DATA = 0x46;
	/**
	 * TrackerSensor class
	 */
	class TrackerSensor extends Ant.GenericChannel {
	    
	    const DEVICE_TYPE = 41; // type: asset tracker
	    const PERIOD = 2048;
	    const DEVICE_RF = 57; // frequency
	
	    hidden var chanAssign;
	
	    var assets;
	    var searching;
	    var deviceCfg;
	    
	   
		var prevPayload = null;
		var subseqFirstPages = 0;
		
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
	            :transmissionType => 0, // pairing search
	            :messagePeriod => PERIOD,
	            :radioFrequency => DEVICE_RF,
	            :searchTimeoutLowPriority => 3, // 3*2.5s = 7.5 seconds   
	            :searchThreshold => 0} );           
	        GenericChannel.setDeviceConfig(deviceCfg);
	
			
			assets = new AssetList();
	        searching = true;
	        
	    }
	
	    function open() {
	        
	        GenericChannel.open();
	        assets.removeAll();
	        //data = new AssetData();
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
	        payload[0] = PAGE_REQUEST_DATA;  
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
	        	var pageNumber = getPageNro(payload);
	        	
	        	// In search state, now we found something
	            if (searching) {
	                searching = false;
	                // request asset identification to get tracker names etc.
	                requestAssetIdentification();
	                // Update our device configuration primarily to see the device number of the sensor we paired to
	                deviceCfg = GenericChannel.getDeviceConfig();
	            }
	            
	            // cases
	            if(pageNumber == PAGE_LOCATION_FIRST && subseqFirstPages == 0) {
	            	// first location page, no previous first pages	            	
	            	subseqFirstPages = 1;          	
	            } 
	            
	            else if(pageNumber == PAGE_LOCATION_FIRST && subseqFirstPages > 0) {
	            	// first location page, some first pages already received
	            	subseqFirstPages++; // check if the asset id's match?
	            	if(subseqFirstPages > 3) { 
        				// handle asset disconnect after 4 first pages
        				assets.removeAsset(parseAssetIdx(payload));
        				System.println("TRACKER DISCONNECT!");
        			}
	            }
	            
	            else if(pageNumber == PAGE_LOCATION_SECOND && prevPayload != null) {
	            	// second location page, and there's a previous payload saved
	            	subseqFirstPages = 0;
	            	var index = parseAssetIdx(payload);
	            	if(getPageNro(prevPayload) == PAGE_LOCATION_FIRST && index == parseAssetIdx(prevPayload)) {
	            		// we have both pages and they refer to same asset id (= can parse)
	            		
	            		var data = assets.getIndex(index);
	            		// if the tracker is known, process. Else request identification
	            		if(data) {
	            			data = parseLocation(data, prevPayload, payload); 
				        	if(data.shouldRemove) {
		                		assets.removeAsset(index);
	                		} else {
	                			assets.putAsset(index, data);
	            			}
	            		} else {
	            			requestAssetIdentification();
	            		}
	            	}
	            }
	            
	            else if(pageNumber == PAGE_IDENTIFICATION_FIRST) {
	            	// first id page, not much to do here
	            	subseqFirstPages = 0;
            	} 
	            
	            else if(pageNumber == PAGE_IDENTIFICATION_SECOND && prevPayload != null) {
	            	subseqFirstPages = 0;
	            	var index = parseAssetIdx(payload);
	            	if(getPageNro(prevPayload) == PAGE_IDENTIFICATION_FIRST && index == parseAssetIdx(prevPayload)) {
	            		// we have both pages and they refer to same asset id (= can parse)
	            		
	            		
	            		var data = assets.getIndex(index);
			        	if(data == null) {
			        		data = new AssetData();
			    		}
			        	data = parseIdentification(data, prevPayload, payload); 
			        	assets.putAsset(index, data);
	            	}
	            }
	            else if(pageNumber == PAGE_DISCONNECT_CMD) {
	            	// disconnect
	            	System.println("PAGE DISCONNECT!");
	            	
	            	assets.removeAll();
	            	closeSensor(); 
	            	// maybe require callback rather than throw an exception
	            	//throw new Exception("Sensor disconnected");
	            	
	            } 
	            
	            else if(pageNumber == PAGE_NO_ASSETS) {
	            	// no assets
	            	assets.removeAll();
            		requestAssetIdentification();
	            }
	            // @todo need to add handlers for pages 80, 81, 82
	            prevPayload = payload;
	            
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
	    private function getPageNro (pload) {
	    	return (pload[0].toNumber() & 0xFF);
	    }
	    private function parseAssetIdx (pload) {
	    	return pload[1] & 0x1F;
	    }
	    private function parseDistance(payload) {
        	return ((payload[2]) | (payload[3] << 8));
        }
        
        private function parseBearing(payload) {
        	var bearingBrad = payload[4];
        	return (1.0 * bearingBrad / 256) * 360;
        }
        
        private function convertSemicircleToDeg(semicircle) {
        	return (1.0 * semicircle / Math.pow(2,31)) * 180;
        }
        private function parseLatitude(payloadFirst, payloadSecond) {
        	var latSemicircle; 
        	latSemicircle = (payloadFirst[6] | (payloadFirst[7] << 8) | (payloadSecond[2] << 16) | (payloadSecond[3] << 24));
        	return convertSemicircleToDeg(latSemicircle);
        }
        private function parseLongitude(payload) {
        	var lonSemicircle; 
        	lonSemicircle = (payload[4] | (payload[5] << 8) | (payload[6] << 16) | (payload[7] << 24));
        	return convertSemicircleToDeg(lonSemicircle);
        }
        
        private function parseSituation(payload) {
        	var s = payload[5];
        	return s & 0x7;
        }
        private function parseLowBattery(payload) {
        	var s = payload[5];
        	return true && ((s >> 3) & 0x1); // cast to boolean
        }
        private function parseGPSLost(payload) {
        	var s = payload[5];
        	return true && ((s >> 4) & 0x1);
        }
        private function parseCommLost(payload) {
        	var s = payload[5];
        	return true && ((s >> 5) & 0x1);
        }
        private function parseShouldRemove(payload) {
        	var s = payload[5];
        	return true && ((s >> 6) & 0x1);
        }
        
        private function parseLocation(data, firstPagePayload, secondPagePayload) {
        	
        	data.index = parseAssetIdx(firstPagePayload);    	
        	data.distance = parseDistance(firstPagePayload);
        	data.bearingDeg = parseBearing(firstPagePayload);   	
        	data.situation = parseSituation(firstPagePayload);
        	data.isLowBattery = parseLowBattery(firstPagePayload);
            data.isGPSLost = parseGPSLost(firstPagePayload);
            data.isCommLost = parseCommLost(firstPagePayload);
            data.shouldRemove = parseShouldRemove(firstPagePayload);
            data.latitude = parseLatitude(firstPagePayload, secondPagePayload);
        	data.longitude = parseLongitude(secondPagePayload);
    		
        	return data;
        }
        
        private function parseColor(payload) {
        	return payload[2];
        }
        
        private function parseType(payload) {
        	return payload[2];
        }
        
       
        private function parseName(payloadFirst, payloadSecond) {
        	
			var nameArr = new [10];
        	for(var i=3; i<8; i++) {
        		nameArr[i-3] = payloadFirst[i];
        	}
        	
        	for(var i=3; i<8; i++) {
        		nameArr[i+2] = payloadSecond[i];
        	}
        	return StringUtil.utf8ArrayToString(nameArr);
        }
       
        
       private function parseIdentification(data, firstPagePayload, secondPagePayload) {
        	
        	data.index = parseAssetIdx(firstPagePayload);
        	data.color = parseColor(firstPagePayload);
        	data.type = parseType(secondPagePayload);
        	data.name = parseName(firstPagePayload, secondPagePayload);
        	
        	return data;
        }
	}
	
	class AssetList {
		hidden var lst = {};
		
		function initialize() {
			lst = {};
		}
		
		function getIndex(index) {
			if(!lst.isEmpty() && lst.hasKey(index)) {
				return lst.get(index);
			}
			return null;
		}
		
		function putAsset(index, data) {
			lst.put(index, data);
		}
		
		function removeAsset(index) {
			lst.remove(index);
		}
		
		function removeAll() {
			lst = {};
		}
		
		function listKeys() {
			return lst.keys();
		}
		
		function getAssets() {
			return lst.values();
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
}
